import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "daemon")

/// Keeps the connected Mac's workspaces in step with its cmux-tui daemon
/// over the link's `daemon` channel: declare capabilities, subscribe, list,
/// then re-list on every tree event (coalesced: one list in flight, one more
/// queued at most).
@MainActor
@Observable
public final class WorkspaceSync {
    public private(set) var tree: DaemonTree?
    public private(set) var identity: String?
    public private(set) var lastError: String?

    @ObservationIgnored public var onTree: (@MainActor (DaemonTree) -> Void)?
    /// A notification was posted on the Mac (terminal agents, `cmux notify`).
    @ObservationIgnored public var onNotification: (@MainActor (NotificationPost) -> Void)?
    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var agents = AgentStates()
    /// The Mac's sidebar order, groups and pins (`list-personal`, `sidebar_layout.get`),
    /// read again after a topology or personal change (`arrangementStale`).
    @ObservationIgnored public private(set) var arrangement: SidebarArrangement?
    @ObservationIgnored private var arrangementStale = true
    /// When an event last arrived per surface (agent state or title): the
    /// only activity time the daemon gives.
    @ObservationIgnored private var activity: [Int: Date] = [:]
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
        eventTask?.cancel()
        client = nil
        connectionSerial += 1
        activity = [:]
        guard let channel else { return }
        await bind(Self.prepare(channel, deviceID: deviceID, deviceName: deviceName), macID: macID, cached: cached)
    }

    /// A `daemon` channel whose client is reading and whose setup batch is on
    /// its way, made without the main actor right after the dial
    /// (verify/perf-latency.md).
    public struct Prepared: Sendable {
        let client: DaemonClient
        let replies: Task<[Result<Data, any Error>], Never>
    }

    /// Starts `channel`'s client and sends the whole setup in one write (one
    /// round trip, not five): declare the client, identify, subscribe, list
    /// agents, list workspaces. The daemon answers a connection's lines in
    /// order; events after the subscribe wait in the client's stream. Does not
    /// wait for the answers (a Mac that pairs holds them until `auth` passes).
    public nonisolated static func prepare(_ channel: any LinkChannel, deviceID: String, deviceName: String) async -> Prepared {
        let client = DaemonClient(channel: channel)
        await client.start()
        let replies = Task.detached { () -> [Result<Data, any Error>] in
            let replies = await client.requests([
                ("set-client-info", [
                    "name": deviceName, "kind": "ios", "device_kind": "iphone", "device_name": deviceName, "device_id": deviceID,
                    // `page-tabs-v1`: the Mac's page tabs read as their page (a phone tab is a simulator tab).
                    "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"],
                ]),
                ("identify", [:]),
                ("subscribe", ["tree_events": "deltas"]),
                ("list-agents", [:]),
                ("list-workspaces", [:]),
            ])
            ConnectTimeline.shared.mark("first_daemon_response")
            return replies
        }
        return Prepared(client: client, replies: replies)
    }

    /// Binds a prepared `daemon` channel for `macID` and publishes its list
    /// when the setup answers arrive.
    public func bind(_ prepared: Prepared, macID: String, cached: [Workspace] = []) async {
        eventTask?.cancel()
        activity = [:]
        arrangement = nil
        arrangementStale = true
        self.macID = macID
        let client = prepared.client
        self.client = client
        connectionSerial += 1
        let events = client.events
        eventTask = Task { [weak self] in
            for await line in events {
                self?.handle(DaemonEvent.parse(line))
            }
        }
        let replies = await prepared.replies.value
        // Bound again meanwhile (another link or Mac): this answer is stale.
        guard self.client === client else { return }
        do {
            _ = try Self.check(replies[0].get())
            let identify = try Self.check(replies[1].get())
            if let data = identify["data"] as? [String: Any] {
                identity = "\(data["app"] as? String ?? "cmux-tui") \(data["version"] as? String ?? "") protocol \(data["protocol"] as? Int ?? 0)"
            }
            _ = try Self.check(replies[2].get())
            if let reply = try? Self.check(replies[3].get()) { applyAgents(reply) }
            let known = (tree?.workspaces ?? []).filter { $0.macID == macID }
            var next = try DaemonTree(reply: replies[4].get(), macID: macID, previous: known.isEmpty ? cached : known, agents: agents)
            next.apply(arrangement)
            tree = next
            lastError = nil
            onTree?(next)
            // The Mac's own order and pins follow in one more round trip.
            Task { await refresh() }
        } catch {
            lastError = LinkController.reason(error)
            log.error("daemon bind failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Marks acpmux sessions with open permissions (workspace "Needs you"), and
    /// what each open ask is when the phone has seen it (`waitingFor`).
    public func setPending(_ pending: [String: Bool], waitingFor: [String: WorkspaceTab.WaitingFor] = [:]) {
        guard agents.pending != pending || agents.waitingFor != waitingFor else { return }
        agents.pending = pending
        agents.waitingFor = waitingFor
        Task { await refresh() }
    }

    func handle(_ event: DaemonEvent) {
        switch event {
        case .titleChanged(let surface, _):
            activity[surface] = Date()
            Task { await refresh() }
        case .treeChanged:
            arrangementStale = true
            Task { await refresh() }
        case .notification(let post):
            onNotification?(post)
            Task { await refresh() }
        case .resubscribe:
            Task {
                guard let client else { return }
                _ = try? await client.request("subscribe", params: ["tree_events": "deltas"])
                arrangementStale = true
                await refresh()
            }
        case .agentChanged(let surface, let state, let agent, let updatedAt):
            // A Mac that reports `updated_at_ms` gives the time; an older one gets the phone's.
            if updatedAt == nil, agents.bySurface[surface]?.state != state { activity[surface] = Date() }
            agents.bySurface[surface] = AgentState(state: state, agent: agent, updatedAt: updatedAt)
            Task { await refresh() }
        case .other:
            break
        }
    }

    private func applyAgents(_ reply: [String: Any]) {
        guard let list = (reply["data"] as? [String: Any])?["agents"] as? [[String: Any]] else { return }
        for agent in list {
            guard let surface = agent["surface"] as? Int else { continue }
            agents.bySurface[surface] = AgentState(json: agent)
        }
    }

    public func refresh() async {
        guard let client else { return }
        if refreshing {
            dirty = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            dirty = false
            do {
                // The arrangement first: nothing may wait between a list's reply and its
                // publication, or an older list could land after a newer one (`listNow`).
                await loadArrangementIfStale(client)
                let reply = try await client.request("list-workspaces")
                var next = try DaemonTree(reply: reply, macID: macID, previous: tree?.workspaces ?? [], agents: agents, activity: activity)
                next.apply(arrangement)
                tree = next
                lastError = nil
                onTree?(next)
            } catch {
                lastError = LinkController.reason(error)
                log.error("list-workspaces failed: \(String(describing: error), privacy: .public)")
                return
            }
        } while dirty
    }

    /// Lists now (outside the coalesced refresh) and publishes the tree, so
    /// a caller that just changed the topology sees its own change.
    @discardableResult
    public func listNow() async throws -> DaemonTree {
        guard let client else { throw DaemonReplyError(message: "Not connected") }
        await loadArrangementIfStale(client)
        let reply = try await client.request("list-workspaces")
        var next = try DaemonTree(reply: reply, macID: macID, previous: tree?.workspaces ?? [], agents: agents, activity: activity)
        next.apply(arrangement)
        tree = next
        lastError = nil
        onTree?(next)
        return next
    }

    /// Reads the order and pins again on the next list (after the phone's own pin or move).
    public func invalidateArrangement() { arrangementStale = true }

    /// Reads the Mac's personal order and pinned tiles when a change may have
    /// moved them. A Mac without either keeps the daemon's order and pin flags.
    private func loadArrangementIfStale(_ client: DaemonClient) async {
        guard arrangementStale else { return }
        arrangementStale = false
        var next = SidebarArrangement()
        if let reply = try? Self.check(await client.request("list-personal")) {
            next.rows = SidebarArrangement.rows(personal: reply)
            next.groups = SidebarArrangement.groups(personal: reply)
            next.rooms = SidebarArrangement.rooms(personal: reply)
            next.roomPins = SidebarArrangement.roomPins(personal: reply)
        }
        if let line = try? await client.resourceRequest("sidebar_layout.get", deadline: .seconds(10)),
           let reply = try? Self.checkResource(line) {
            next.pins = SidebarArrangement.pins(layout: reply)
        }
        // Bound to another Mac meanwhile: not this one's.
        guard self.client === client else { return }
        arrangement = next
    }

    /// Throws a `cmux.protocol/2` failure; returns the response object.
    @discardableResult
    static func checkResource(_ line: Data) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? [String: Any]
            throw DaemonReplyError(message: error?["message"] as? String ?? "request failed", code: error?["code"] as? String)
        }
        return object
    }

    /// Throws a daemon error line; returns the parsed reply object.
    @discardableResult
    static func check(_ reply: Data) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        if object["ok"] as? Bool == false {
            throw DaemonReplyError(message: object["error"] as? String ?? "request failed", code: object["error_code"] as? String)
        }
        return object
    }
}
