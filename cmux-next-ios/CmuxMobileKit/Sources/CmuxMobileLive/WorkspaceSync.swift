import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "daemon")

/// Keeps the connected Mac's workspaces in step with its cmux-tui daemon
/// over the link's `daemon` channel: declare capabilities, subscribe, list,
/// then apply deltas off the main actor. Reconnects, gaps and unsupported
/// events recover through a coalesced full snapshot.
@MainActor
@Observable
public final class WorkspaceSync {
    public private(set) var tree: DaemonTree?
    public private(set) var identity: String?
    public private(set) var lastError: String? {
        didSet { if lastError != oldValue { onErrorChanged?() } }
    }
    /// Updates explicit diagnostics when a later refresh fails or recovers.
    @ObservationIgnored var onErrorChanged: (@MainActor () -> Void)?

    @ObservationIgnored public var onTree: (@MainActor (DaemonTree) -> Void)?
    /// Metadata-only changes; consumers can update just these workspace rows.
    @ObservationIgnored public var onRows: (@MainActor (DaemonTree, Set<String>, Bool) -> Void)?
    /// A notification was posted on the Mac (terminal agents, `cmux notify`).
    @ObservationIgnored public var onNotification: (@MainActor (NotificationPost) -> Void)?
    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var projection = WorkspaceProjection()
    private struct QueuedEvent {
        var event: DaemonEvent
        var sequence: UInt64?
    }
    @ObservationIgnored private var queued: [QueuedEvent] = []
    /// Events received before the latest snapshot request are covered by it.
    /// Events received during capture must replay, even before its reply:
    /// the daemon writes subscription events from a separate thread. Tests set it.
    @ObservationIgnored var snapshotSequence: UInt64 = 0
    /// Coarse changes can affect arrangement as well as the tree. Their
    /// coverage starts before the arrangement requests, not before the list.
    @ObservationIgnored private var arrangementSequence: UInt64 = 0
    @ObservationIgnored private var pendingChanged = false
    @ObservationIgnored private var initializing = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var agents = AgentStates()
    /// The Mac's sidebar order, groups and pins (`list-personal`, `sidebar_layout.get`),
    /// read again after a topology or personal change (`arrangementStale`).
    @ObservationIgnored public private(set) var arrangement: SidebarArrangement?
    @ObservationIgnored private var arrangementStale = true
    /// When an event last arrived per surface (agent state or title): the
    /// only activity time the daemon gives.
    @ObservationIgnored private(set) var activity: [Int: Date] = [:]
    /// Each surface's last title on this connection: a title set again to the
    /// same text (a shell prompt does it constantly) is not activity, and
    /// re-listing for it republished every workspace to the store.
    @ObservationIgnored private var titles: [Int: String] = [:]
    /// Title events dropped as repeats (tests).
    @ObservationIgnored private(set) var titleEventsIgnored = 0
    @ObservationIgnored public private(set) var macID = ""
    /// Counts bound `daemon` channels: names the current connection (a new
    /// channel, even to the same Mac, is a new one).
    @ObservationIgnored public private(set) var connectionSerial = 0
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let deviceName: String

    public init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    /// The live client (nil while unbound), for Chief and other daemon users.
    public var daemon: DaemonClient? { client }

    /// Binds a fresh `daemon` channel for `macID` (nil unbinds). `cached` is
    /// what the list shows for the Mac before this answer (the launch
    /// snapshot): the first live list keeps those rows' known activity times,
    /// so it reconciles with them instead of resorting every row to "no
    /// activity seen yet".
    public func bind(_ channel: (any LinkChannel)?, macID: String, cached: [Workspace] = []) async {
        stopUpdates()
        client = nil
        connectionSerial += 1
        activity = [:]
        titles = [:]
        guard let channel else {
            lastError = nil
            identity = nil
            return
        }
        await bind(Self.prepare(channel, deviceID: deviceID, deviceName: deviceName), macID: macID, cached: cached)
    }

    /// A `daemon` channel whose client is reading and whose setup batch is on
    /// its way, made without the main actor right after the dial
    /// (verify/perf-latency.md).
    public struct Prepared: Sendable {
        let client: DaemonClient
        let replies: Task<[Result<DaemonClient.ReceivedLine, any Error>], Never>
    }

    /// Starts `channel`'s client and sends the whole setup in one write (one
    /// round trip, not five): declare the client, identify, subscribe, list
    /// agents, list workspaces. The daemon answers a connection's lines in
    /// order; events after the subscribe wait in the client's stream. Does not
    /// wait for the answers (a Mac that pairs holds them until `auth` passes).
    public nonisolated static func prepare(
        _ channel: any LinkChannel, deviceID: String, deviceName: String,
        authorizationTimeout: Duration = LinkPairing.authorizationTimeout,
        replyTimeout: Duration = DaemonClient.defaultDeadline
    ) async -> Prepared {
        let client = DaemonClient(channel: channel, orderedEvents: true)
        await client.start()
        let replies = Task.detached { () -> [Result<DaemonClient.ReceivedLine, any Error>] in
            let replies = await client.requestsOrdered([
                ("set-client-info", [
                    "name": deviceName, "kind": "ios", "device_kind": "iphone", "device_name": deviceName, "device_id": deviceID,
                    // `page-tabs-v1`: the Mac's page tabs read as their page (a phone tab is a simulator tab).
                    "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"],
                ]),
                ("identify", [:]),
                ("subscribe", ["tree_events": "deltas"]),
                ("list-agents", [:]),
                ("list-workspaces", [:]),
            ], deadline: authorizationTimeout + replyTimeout)
            // This eager batch can be held behind auth's human approval. Only
            // setup gets that grace; subsequent daemon reads keep their normal bound.
            ConnectTimeline.shared.mark("first_daemon_response")
            return replies
        }
        return Prepared(client: client, replies: replies)
    }

    /// Binds a prepared `daemon` channel for `macID` and publishes its list
    /// when the setup answers arrive.
    public func bind(_ prepared: Prepared, macID: String, cached: [Workspace] = []) async {
        stopUpdates()
        initializing = true
        projection = WorkspaceProjection()
        let projection = projection
        activity = [:]
        titles = [:]
        agents.bySurface = [:]
        arrangement = nil
        arrangementStale = true
        self.macID = macID
        let client = prepared.client
        self.client = client
        connectionSerial += 1
        let events = client.orderedEvents
        eventTask = Task.detached { [weak self] in
            for await line in events {
                guard !Task.isCancelled else { break }
                let event = DaemonEvent.parse(line.data)
                await self?.receive(event, sequence: line.sequence, from: client)
            }
        }
        let replies = await prepared.replies.value
        // Bound again meanwhile (another link or Mac): this answer is stale.
        guard self.client === client else { return }
        do {
            let setup = try await Task.detached { try Self.decodeSetup(replies.map { $0.map(\.data) }) }.value
            guard self.client === client else { return }
            identity = setup.identity
            agents.bySurface = setup.agents.bySurface
            let snapshot = try replies[4].get()
            let known = (tree?.workspaces ?? []).filter { $0.macID == macID }
            let next = try await projection.reset(snapshot: snapshot.data, macID: macID,
                                                  previous: known.isEmpty ? cached : known,
                                                  agents: agents, activity: activity, arrangement: arrangement)
            guard self.client === client else { return }
            // Setup subscribed before its list. Replay every setup event;
            // reply arrival is not a watermark for the captured snapshot.
            discardBeforeSnapshot()
            tree = next
            lastError = nil
            initializing = false
            onTree?(next)
            drain()
            // The Mac's own order and pins follow in one more round trip.
            Task {
                guard self.client === client else { return }
                await refresh()
            }
        } catch {
            guard self.client === client else { return }
            initializing = false
            lastError = LinkController.reason(error)
            log.error("daemon bind failed: \(String(describing: error), privacy: .public)")
            drain()
        }
    }

    /// Marks acpmux sessions with open permissions (workspace "Needs you"), and
    /// what each open ask is when the phone has seen it (`waitingFor`).
    public func setPending(_ pending: [String: Bool], waitingFor: [String: WorkspaceTab.WaitingFor] = [:]) {
        guard agents.pending != pending || agents.waitingFor != waitingFor else { return }
        agents.pending = pending
        agents.waitingFor = waitingFor
        pendingChanged = true
        drain()
    }

    private func stopUpdates() {
        eventTask?.cancel()
        refreshTask?.cancel()
        updateTask?.cancel()
        eventTask = nil
        refreshTask = nil
        updateTask = nil
        queued = []
        snapshotSequence = 0
        arrangementSequence = 0
        pendingChanged = false
        initializing = false
        dirty = false
    }

    private func receive(_ event: DaemonEvent, sequence: UInt64, from client: DaemonClient) {
        guard self.client === client else { return }
        enqueue(event, sequence: sequence)
    }

    func handle(_ event: DaemonEvent) { enqueue(event, sequence: nil) }

    /// An event at a wire position, as the daemon's stream delivers it (tests).
    func handle(_ event: DaemonEvent, sequence: UInt64) { enqueue(event, sequence: sequence) }

    private func enqueue(_ event: DaemonEvent, sequence: UInt64?) {
        guard event != .other else { return }
        let entry = QueuedEvent(event: event, sequence: sequence)
        // An event the latest snapshot covers is dropped before it counts for anything: a stale
        // title recorded as the surface's last one hid the next real event with the same text.
        guard !isBeforeSnapshot(entry) else { return }
        switch event {
        case .titleChanged(let surface, let title):
            // A title set again to the same text is not activity, and applying it
            // republished the workspace for nothing.
            guard titles.updateValue(title, forKey: surface) != title else {
                titleEventsIgnored += 1
                return
            }
            activity[surface] = Date()
        case .resubscribe:
            // Title events may have been lost: the next one is news whatever it says.
            titles = [:]
        default:
            break
        }
        if event == .treeChanged, let index = queued.firstIndex(where: { $0.event == .treeChanged }) {
            // One pending invalidation covers the burst. Keep its newest
            // position so a change during capture still requests a follow-up.
            queued[index] = entry
        } else {
            queued.append(entry)
        }
        drain()
    }

    private func isBeforeSnapshot(_ entry: QueuedEvent) -> Bool {
        guard let sequence = entry.sequence else { return false }
        switch entry.event {
        case .agentChanged: return false
        case .treeChanged: return sequence <= arrangementSequence
        // Memory-only notification text and subscription loss aren't in a tree.
        case .notification, .resubscribe: return false
        default: return sequence <= snapshotSequence
        }
    }

    private func discardBeforeSnapshot() {
        queued.removeAll(where: isBeforeSnapshot)
    }

    private func drain() {
        guard !initializing, refreshTask == nil, updateTask == nil, let client else { return }
        let projection = projection
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.client === client { updateTask = nil } }
            do {
                while self.client === client, refreshTask == nil, !Task.isCancelled {
                    if pendingChanged {
                        pendingChanged = false
                        let update = try await projection.updateAgents(agents: agents, activity: activity)
                        guard self.client === client, !Task.isCancelled else { return }
                        if let update { publish(update, agentChanged: true) }
                    } else if !queued.isEmpty {
                        // Refresh-only markers carry no payload. Drain the
                        // real updates first so an invalidation burst cannot
                        // starve title/agent publication behind network trips.
                        let index = queued.firstIndex(where: { $0.event != .treeChanged }) ?? queued.startIndex
                        let event = queued.remove(at: index).event
                        var agentChanged = false
                        switch event {
                        case .titleChanged:
                            // Stamped as activity when it arrived (`enqueue`).
                            break
                        case .agentChanged(let surface, let state, let agent, let updatedAt, let harnessSession):
                            if updatedAt == nil, agents.bySurface[surface]?.state != state { activity[surface] = Date() }
                            agents.bySurface[surface] = AgentState(state: state, agent: agent, updatedAt: updatedAt, harnessSession: harnessSession)
                            agentChanged = true
                        case .notification(let post):
                            onNotification?(post)
                        case .treeChanged:
                            arrangementStale = true
                        case .resubscribe:
                            arrangementStale = true
                            _ = try await client.request("subscribe", params: ["tree_events": "deltas"])
                        default:
                            break
                        }
                        let update = try await projection.apply(event, agents: agents, activity: activity)
                        guard self.client === client, !Task.isCancelled else { return }
                        if let update { publish(update, agentChanged: agentChanged) }
                    } else {
                        return
                    }
                }
            } catch {
                guard self.client === client, !Task.isCancelled else { return }
                // The current drain ends before the refresh waits for it.
                Task {
                    guard self.client === client else { return }
                    await refresh()
                }
            }
        }
    }

    private func publish(_ update: WorkspaceProjection.Update, agentChanged: Bool) {
        tree = update.tree
        lastError = nil
        if !update.topology, let onRows {
            onRows(update.tree, update.changedWorkspaceIDs, agentChanged)
        } else {
            onTree?(update.tree)
        }
    }

    private nonisolated static func decodeSetup(_ replies: [Result<Data, any Error>]) throws -> (identity: String?, agents: AgentStates) {
        _ = try check(replies[0].get())
        let identify = try check(replies[1].get())["data"] as? [String: Any]
        _ = try check(replies[2].get())
        var agents = AgentStates()
        if let reply = try? check(replies[3].get()), let list = (reply["data"] as? [String: Any])?["agents"] as? [[String: Any]] {
            for agent in list {
                if let surface = agent["surface"] as? Int { agents.bySurface[surface] = AgentState(json: agent) }
            }
        }
        let identity = identify.map { "\($0["app"] as? String ?? "cmux-tui") \($0["version"] as? String ?? "") protocol \($0["protocol"] as? Int ?? 0)" }
        return (identity, agents)
    }

    public func refresh() async {
        if let refreshTask {
            dirty = true
            await refreshTask.value
            return
        }
        guard let client, !initializing else { return }
        let projection = projection
        let task = Task { [weak self] in
            guard let self else { return }
            // Let a delta already being mapped commit before replacing its snapshot.
            await updateTask?.value
            defer {
                if self.client === client {
                    refreshTask = nil
                    drain()
                }
            }
            repeat {
                dirty = false
                do {
                    let reloadArrangement = arrangementStale
                    let arrangementCoveredThrough = await client.receivedPosition
                    guard self.client === client, !Task.isCancelled else { return }
                    // Locally injected invalidations have no wire position;
                    // only those already queued before capture are covered.
                    if reloadArrangement {
                        queued.removeAll { $0.event == .treeChanged && $0.sequence == nil }
                    }
                    await loadArrangementIfStale(client)
                    let coveredThrough = await client.receivedPosition
                    let reply = try await client.requestOrdered("list-workspaces")
                    guard self.client === client, !Task.isCancelled else { return }
                    let next = try await projection.reset(snapshot: reply.data, macID: macID,
                                                          previous: tree?.workspaces ?? [], agents: agents,
                                                          activity: activity, arrangement: arrangement)
                    guard self.client === client, !Task.isCancelled else { return }
                    snapshotSequence = coveredThrough
                    if reloadArrangement { arrangementSequence = arrangementCoveredThrough }
                    discardBeforeSnapshot()
                    tree = next
                    lastError = nil
                    onTree?(next)
                } catch {
                    guard self.client === client, !Task.isCancelled else { return }
                    lastError = LinkController.reason(error)
                    log.error("list-workspaces failed: \(String(describing: error), privacy: .public)")
                    return
                }
            } while dirty && !Task.isCancelled
        }
        refreshTask = task
        await task.value
    }

    /// Coalesces with an in-flight list and requires a new list after it, so a
    /// caller that just changed topology sees its own change without stale publication.
    @discardableResult
    public func listNow() async throws -> DaemonTree {
        guard let client else { throw DaemonReplyError(message: "Not connected") }
        await refresh()
        guard self.client === client, let tree else { throw DaemonReplyError(message: "Not connected") }
        if let lastError { throw DaemonReplyError(message: lastError) }
        return tree
    }

    /// Reads the order and pins again on the next list (after the phone's own pin or move).
    public func invalidateArrangement() { arrangementStale = true }

    /// Reads the Mac's personal order and pinned tiles when a change may have
    /// moved them. A Mac without either keeps the daemon's order and pin flags.
    private func loadArrangementIfStale(_ client: DaemonClient) async {
        guard arrangementStale else { return }
        arrangementStale = false
        let personal = try? await client.request("list-personal")
        let layout = try? await client.resourceRequest("sidebar_layout.get", deadline: .seconds(10))
        let next = await Task.detached {
            var next = SidebarArrangement()
            if let personal, let reply = try? Self.check(personal) {
                next.rows = SidebarArrangement.rows(personal: reply)
                next.groups = SidebarArrangement.groups(personal: reply)
                next.rooms = SidebarArrangement.rooms(personal: reply)
                next.roomPins = SidebarArrangement.roomPins(personal: reply)
            }
            if let layout, let reply = try? Self.checkResource(layout) {
                next.pins = SidebarArrangement.pins(layout: reply)
            }
            return next
        }.value
        // Bound to another Mac meanwhile: not this one's.
        guard self.client === client else { return }
        arrangement = next
    }

    /// Throws a `cmux.protocol/2` failure; returns the response object.
    @discardableResult
    nonisolated static func checkResource(_ line: Data) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any]
            throw DaemonReplyError(message: error?["message"] as? String ?? "request failed", code: error?["code"] as? String)
        }
        return object
    }

    /// Throws a daemon error line; returns the parsed reply object.
    @discardableResult
    nonisolated static func check(_ reply: Data) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        if object["ok"] as? Bool == false {
            throw DaemonReplyError(message: object["error"] as? String ?? "request failed", code: object["error_code"] as? String)
        }
        return object
    }
}
