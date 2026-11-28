import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import Observation
import OSLog
import Synchronization

private let log = Logger(subsystem: "dev.cmux.mobile", category: "daemon")

/// Keeps the connected Mac's workspaces in step with its cmux-tui daemon
/// over the link's `daemon` channel: declare capabilities, subscribe, list,
/// then apply deltas off the main actor. Reconnects, gaps and unsupported
/// events recover through a coalesced full snapshot.
@MainActor
@Observable
public final class WorkspaceSync {
    public private(set) var tree: DaemonTree? {
        didSet { tabsBySurface = nil }
    }
    public private(set) var identity: String?
    /// What the phone shows of this Mac (the tree, its activity times, its
    /// order and pins) is the last link's: unbound, or bound again and its
    /// first answer not in yet. Kept on screen meanwhile, never cleared, and
    /// replaced by the new link's values as they arrive (Leo, 2026-11-22:
    /// "shit shouldnt somehow instantly dissipate after i navigate away for
    /// like one second").
    public private(set) var isStale = false
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
    /// A terminal tab drew output on the Mac (`surface-output`), or (nil) any
    /// may have: the event stream started again, so output in between was not
    /// heard. Grid cards read the Mac's screen only after this.
    @ObservationIgnored public var onTerminalOutput: (@MainActor (String?) -> Void)?
    /// The tabs of each surface in `tree`, built on the first output after it changes.
    @ObservationIgnored private var tabsBySurface: [Int: [String]]?
    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var setupTask: Task<[Result<DaemonClient.ReceivedLine, any Error>], Never>?
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
    /// The daemon takes `known` on `list-workspaces` (`list-workspaces-known-v1` in its
    /// `identify`): a list then answers `unchanged` when the held tree is current. An older
    /// daemon (and the Mac lane in front of it, which refuses a field it does not know) never gets it.
    @ObservationIgnored private var listsKnown = false
    @ObservationIgnored private var agents = AgentStates()
    /// When each surface's agent last started a turn the person prompted (Jump to Last
    /// Prompt), kept across reconnects as the Mac's `AgentRoster.lastPromptBySurface` is.
    @ObservationIgnored public private(set) var lastPromptAt: [Int: Date] = [:]
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
    /// Which Macs take the first window (`ListFirstWindow`); tests use their own suite.
    @ObservationIgnored var firstWindowDefaults: UserDefaults = .standard

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
        let oldClient = client
        client = nil
        connectionSerial += 1
        let serial = connectionSerial
        // The activity times stay with the rows they date until the next
        // link's list replaces them: only the title repeats are per link.
        titles = [:]
        if tree != nil { isStale = true }
        if channel == nil {
            lastError = nil
            identity = nil
        }
        if let oldClient { await oldClient.close() }
        guard let channel else { return }
        guard connectionSerial == serial, !Task.isCancelled else {
            await channel.close(code: "eof", reason: "binding superseded")
            return
        }
        let prepared = await Self.prepare(channel, deviceID: deviceID, deviceName: deviceName,
                                          firstWindow: ListFirstWindow.honors(macID, defaults: firstWindowDefaults),
                                          macID: macID)
        guard connectionSerial == serial, !Task.isCancelled else {
            prepared.replies.cancel()
            await prepared.client.close()
            return
        }
        await bind(prepared, macID: macID, cached: cached)
    }

    /// A `daemon` channel whose client is reading and whose setup batch is on
    /// its way, made without the main actor right after the dial
    /// (verify/perf-latency.md).
    public struct Prepared: Sendable {
        let client: DaemonClient
        let replies: Task<[Result<DaemonClient.ReceivedLine, any Error>], Never>
        /// The setup list carried `known` (`setupSendsKnown`).
        var sentKnown = false
        /// The setup list asked for the first window (`ListFirstWindow`).
        var sentFirstWindow = false
        /// The setup list sent the revision of the tree this process held for the Mac (`heldKnown`).
        var sentHeld: WorkspaceProjection.KnownTree?
    }

    /// The revision of the last whole tree each Mac's list gave this process, so the setup batch
    /// of the next link to that Mac (a redial: a foreground return, a network change) can send it
    /// as `known`. Written before `identify` answers, like `setupSendsKnown`.
    nonisolated static let heldKnown = Mutex<[String: WorkspaceProjection.KnownTree]>([:])

    /// Records what `projection` now holds for `macID` (nil: a list with no revision).
    nonisolated static func noteHeld(_ known: WorkspaceProjection.KnownTree?, macID: String) {
        heldKnown.withLock { $0[macID] = known }
    }

    /// Whether the last daemon this process identified takes `known` on `list-workspaces`.
    /// The setup batch is written before `identify` answers, so its list carries `known` (`{}`:
    /// the reply then has the tree's revision, and `refresh()`'s check after it costs the
    /// daemon's `unchanged` line, not the whole tree again) only on this word from the last
    /// connection. A Mac that refuses it gets its list again without it (`bind`).
    nonisolated static let setupSendsKnown = Mutex(false)

    /// Starts `channel`'s client and sends the whole setup in one write (one
    /// round trip, not eight): declare the client, identify, subscribe, list
    /// agents, list workspaces, then the Mac's order and pins (`list-personal`,
    /// `sidebar_layout.get`), so the first list drawn is already the settled one
    /// (they came three serial round trips later from `refresh()`). The daemon answers a connection's lines in
    /// order; events after the subscribe wait in the client's stream. Does not
    /// wait for the answers (a Mac that pairs holds them until `auth` passes).
    /// With `firstWindow` (the Mac advertised `list-workspaces-page-v1` last time) the list
    /// is the first window only (`ListFirstWindow`); the whole tree follows after it is drawn.
    public nonisolated static func prepare(
        _ channel: any LinkChannel, deviceID: String, deviceName: String,
        firstWindow: Bool = false,
        macID: String? = nil,
        authorizationTimeout: Duration = LinkPairing.authorizationTimeout,
        replyTimeout: Duration = DaemonClient.defaultDeadline,
        sendsKnown: Bool? = nil
    ) async -> Prepared {
        let sendsKnown = sendsKnown ?? setupSendsKnown.withLock { $0 }
        // A redial to a Mac whose tree this process holds sends that tree's revision: a Mac
        // that has not changed answers `unchanged` and the phone keeps what it shows (no whole
        // tree, no first window) (Leo, 2026-11-24: "deltas can be sipped and maintained").
        let held = sendsKnown ? macID.flatMap { id in heldKnown.withLock { $0[id] } } : nil
        let listParams = held.map { Self.listParams(known: $0, sendsKnown: true) }
            ?? Self.setupListParams(sendsKnown: sendsKnown, firstWindow: firstWindow)
        let client = DaemonClient(channel: channel, orderedEvents: true)
        await client.start()
        let replies = Task.detached { () -> [Result<DaemonClient.ReceivedLine, any Error>] in
            let replies = await client.requestsOrdered([
                ("set-client-info", [
                    "name": deviceName, "kind": "ios", "device_kind": "iphone", "device_name": deviceName, "device_id": deviceID,
                    // `page-tabs-v1`: the Mac's page tabs read as their page (a phone tab is a simulator tab).
                    "capabilities": WorkspaceSync.clientCapabilities,
                ]),
                ("identify", [:]),
                ("subscribe", ["tree_events": "deltas"]),
                ("list-agents", [:]),
                ("list-workspaces", listParams),
                ("list-personal", [:]),
            ], resources: [("sidebar_layout.get", [:])], deadline: authorizationTimeout + replyTimeout)
            // This eager batch can be held behind auth's human approval. Only
            // setup gets that grace; subsequent daemon reads keep their normal bound.
            ConnectTimeline.shared.mark("first_daemon_response")
            return replies
        }
        return Prepared(client: client, replies: replies, sentKnown: sendsKnown, sentFirstWindow: firstWindow && held == nil,
                        sentHeld: held)
    }

    /// Binds a prepared `daemon` channel for `macID` and publishes its list
    /// when the setup answers arrive.
    public func bind(_ prepared: Prepared, macID: String, cached: [Workspace] = []) async {
        stopUpdates()
        let oldClient = client
        initializing = true
        // The same Mac's projection, kept for a setup list answered `unchanged`.
        let heldProjection = macID == self.macID && tree != nil ? projection : nil
        projection = WorkspaceProjection()
        let projection = projection
        // The same Mac again (a redial): its activity times, order and pins
        // stay, marked stale (`isStale`, `arrangementStale`), for the first
        // list to keep and the next reads to replace. Another Mac's never do.
        if macID != self.macID {
            activity = [:]
            arrangement = nil
        }
        if tree != nil { isStale = true }
        titles = [:]
        agents.bySurface = [:]
        arrangementStale = true
        listsKnown = false
        self.macID = macID
        let client = prepared.client
        self.client = client
        setupTask = prepared.replies
        connectionSerial += 1
        let events = client.orderedEvents
        eventTask = Task.detached { [weak self] in
            for await line in events {
                guard !Task.isCancelled else { break }
                let event = DaemonEvent.parse(line.data)
                await self?.receive(event, sequence: line.sequence, from: client)
            }
        }
        // Publish the new owner before closing the old one; close can suspend
        // while another bind arrives. Stale cleanup must never replace that owner.
        if let oldClient, oldClient !== client { await oldClient.close() }
        let replies = await withTaskCancellationHandler {
            await prepared.replies.value
        } onCancel: {
            prepared.replies.cancel()
        }
        // Bound again meanwhile (another link or Mac): this answer is stale.
        guard self.client === client, !Task.isCancelled else {
            await closeFailedClient(client)
            return
        }
        setupTask = nil
        // A missing transport reply invalidates the subscription. A server's
        // explicit rejection is different: keep its live channel so a later
        // workspace event can recover the baseline without another bind.
        // The arrangement's two reads (after the setup's five) are best effort, as in `refresh()`.
        let transportError = replies.prefix(Self.setupCount).compactMap { result -> (any Error)? in
            if case .failure(let error) = result { return error }
            return nil
        }.first
        if let error = transportError {
            lastError = LinkController.reason(error)
            identity = nil
            await closeFailedClient(client)
            return
        }
        do {
            let setup = try await Task.detached { try Self.decodeSetup(replies.map { $0.map(\.data) }) }.value
            guard self.client === client, !Task.isCancelled else {
                await closeFailedClient(client)
                return
            }
            identity = setup.identity
            listsKnown = setup.listsKnown
            Self.setupSendsKnown.withLock { $0 = setup.listsKnown }
            ListFirstWindow.note(macID, honors: setup.pages, defaults: firstWindowDefaults)
            // A reconnect's list counts a prompt only by its own time (a turn already running
            // when the link came back is not a new prompt at the moment it is seen).
            for (surface, state) in setup.agents.bySurface where state.updatedAt != nil {
                notePrompt(surface, from: agents.bySurface[surface], to: state)
            }
            agents.bySurface = setup.agents.bySurface
            if replies.count == Self.setupCount + 2, case .success(let personal) = replies[Self.setupCount],
               case .success(let layout) = replies[Self.setupCount + 1] {
                // Read on this connection after the subscribe: events before the first of the
                // two replies are already in it.
                let next = await Task.detached { Self.arrangement(personal: personal.data, layout: layout.data) }.value
                guard self.client === client, !Task.isCancelled else {
                    await closeFailedClient(client)
                    return
                }
                arrangement = next
                arrangementStale = false
                arrangementSequence = personal.sequence
            }
            var snapshot = try replies[4].get()
            if prepared.sentKnown || prepared.sentFirstWindow, (try? Self.check(snapshot.data)) == nil {
                // Sent `known` or `limit` on the last Mac's word and this one refused it: list
                // again with only what this connection's `identify` advertised.
                snapshot = try await client.requestOrdered("list-workspaces", params: Self.setupListParams(
                    sendsKnown: setup.listsKnown, firstWindow: setup.pages))
                guard self.client === client, !Task.isCancelled else {
                    await closeFailedClient(client)
                    return
                }
            }
            var next: DaemonTree
            if let sent = prepared.sentHeld, Self.isUnchanged(snapshot.data), let heldProjection,
               await heldProjection.known == sent, let current = tree {
                // The Mac's tree is the one this phone holds: keep it, with this link's agents
                // and arrangement, instead of reading it again.
                self.projection = heldProjection
                let update = try await heldProjection.updateAgents(agents: agents, activity: activity)
                let rearranged = await heldProjection.rearrange(arrangement)
                next = rearranged ?? update?.tree ?? current
                guard self.client === client, !Task.isCancelled else {
                    await closeFailedClient(client)
                    return
                }
            } else {
                if prepared.sentHeld != nil, Self.isUnchanged(snapshot.data) {
                    // `unchanged`, but this sync no longer holds that tree: read it whole.
                    snapshot = try await client.requestOrdered("list-workspaces", params: Self.setupListParams(
                        sendsKnown: setup.listsKnown, firstWindow: false))
                    guard self.client === client, !Task.isCancelled else {
                        await closeFailedClient(client)
                        return
                    }
                }
                let known = (tree?.workspaces ?? []).filter { $0.macID == macID }
                let kept = known.isEmpty ? cached : known
                next = try await projection.reset(snapshot: snapshot.data, macID: macID,
                                                  previous: kept,
                                                  agents: agents, activity: activity, arrangement: arrangement)
                guard self.client === client, !Task.isCancelled else {
                    await closeFailedClient(client)
                    return
                }
                Self.noteHeld(await projection.known, macID: macID)
                // A first window: draw it over the rows already held; the whole tree follows
                // from `refresh()` below, in the background.
                if ListFirstWindow.isPartial(snapshot.data) { next = ListFirstWindow.drawn(next, keeping: kept) }
            }
            // Setup subscribed before its list. Replay every setup event;
            // reply arrival is not a watermark for the captured snapshot.
            discardBeforeSnapshot()
            tree = next
            isStale = false
            lastError = nil
            initializing = false
            onTree?(next)
            onTerminalOutput?(nil)
            drain()
            // The Mac's order and pins came with the setup; a Mac that failed either read
            // gets them here (`arrangementStale`), and the list is checked once more.
            Task {
                guard self.client === client else { return }
                await refresh()
            }
        } catch {
            guard self.client === client, !Task.isCancelled else {
                await closeFailedClient(client)
                return
            }
            initializing = false
            lastError = LinkController.reason(error)
            log.error("daemon bind failed: \(String(describing: error), privacy: .public)")
            drain()
        }
    }

    /// Marks acpmux sessions with open permissions (workspace "Needs you"), and
    /// what each open ask is when the phone has seen it (`waitingFor`), and each chat's
    /// title (`chatTitles`: an unnamed chat tab and its workspace read as it).
    public func setPending(_ pending: [String: Bool], waitingFor: [String: WorkspaceTab.WaitingFor] = [:],
                           chatTitles: [String: String] = [:]) {
        guard agents.pending != pending || agents.waitingFor != waitingFor || agents.chatTitles != chatTitles else { return }
        agents.pending = pending
        agents.waitingFor = waitingFor
        agents.chatTitles = chatTitles
        pendingChanged = true
        drain()
    }

    /// ``setPending(_:waitingFor:chatTitles:)`` for the chats in `rows` only (nil: the chat went):
    /// every other chat's entry stands. A row whose pending and title did not change, with the
    /// same open asks, costs a lookup, not a pass over every chat.
    public func setPending(rows: [String: AcpmuxSession?], waitingFor: [String: WorkspaceTab.WaitingFor]) {
        var changed = agents.waitingFor != waitingFor
        if changed { agents.waitingFor = waitingFor }
        for (id, row) in rows {
            let pending = row.map { $0.pendingPermissions > 0 }
            let title = row?.title
            if agents.pending[id] != pending {
                agents.pending[id] = pending
                changed = true
            }
            if agents.chatTitles[id] != title {
                agents.chatTitles[id] = title
                changed = true
            }
        }
        guard changed else { return }
        pendingChanged = true
        drain()
    }

    private func stopUpdates() {
        setupTask?.cancel()
        setupTask = nil
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

    /// Setup can fail after the client has started its reader. Clear the
    /// current owner before awaiting close so a retry cannot inherit the
    /// failed reader or its queued events.
    private func closeFailedClient(_ candidate: DaemonClient) async {
        if self.client === candidate {
            self.client = nil
            stopUpdates()
        }
        await candidate.close()
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
        if case .surfaceOutput(let surface) = event {
            terminalOutput(surface)
            return
        }
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

    private func terminalOutput(_ surface: Int) {
        guard let onTerminalOutput, let tree else { return }
        if tabsBySurface == nil {
            var map: [Int: [String]] = [:]
            for (tab, surface) in tree.surfaces { map[surface, default: []].append(tab) }
            tabsBySurface = map
        }
        for tab in tabsBySurface?[surface] ?? [] { onTerminalOutput(tab) }
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
                            let next = AgentState(state: state, agent: agent, updatedAt: updatedAt, harnessSession: harnessSession)
                            notePrompt(surface, from: agents.bySurface[surface], to: next)
                            agents.bySurface[surface] = next
                            agentChanged = true
                        case .notification(let post):
                            onNotification?(post)
                        case .treeChanged:
                            arrangementStale = true
                        case .resubscribe:
                            arrangementStale = true
                            _ = try await client.request("subscribe", params: ["tree_events": "deltas"])
                            onTerminalOutput?(nil)
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

    /// The Mac's rule (`AgentRoster.startsPromptedTurn`): an agent that starts working, not one
    /// resuming from an approval, began a turn the person prompted. The report has no source,
    /// so a hook's repeated `working` with a new time counts as the Mac counts it.
    nonisolated static func startsPromptedTurn(from old: AgentState?, to new: AgentState) -> Bool {
        guard new.state == "working" else { return false }
        if old?.state == "working" { return new.updatedAt != nil && old?.updatedAt != new.updatedAt }
        return old?.state != "blocked"
    }

    private func notePrompt(_ surface: Int, from old: AgentState?, to new: AgentState) {
        guard Self.startsPromptedTurn(from: old, to: new) else { return }
        let at = new.updatedAt ?? Date()
        lastPromptAt[surface] = max(lastPromptAt[surface] ?? at, at)
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

    private nonisolated static func decodeSetup(_ replies: [Result<Data, any Error>]) throws -> (identity: String?, agents: AgentStates, listsKnown: Bool, pages: Bool) {
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
        let capabilities = identify?["capabilities"] as? [String] ?? []
        return (identity, agents, capabilities.contains(Self.knownCapability), capabilities.contains(ListFirstWindow.capability))
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
                    // What the phone holds goes back as `known` ({} before a whole list gave
                    // a revision), so a current tree costs the daemon's ~300-byte `unchanged`
                    // answer instead of the whole tree (1.7 MB at 1,000 workspaces).
                    let held = listsKnown ? await projection.known : nil
                    let sendsKnown = listsKnown
                    let params = Self.listParams(known: held, sendsKnown: sendsKnown)
                    let reply = try await client.requestOrdered("list-workspaces", params: params)
                    guard self.client === client, !Task.isCancelled else { return }
                    if sendsKnown, Self.isUnchanged(reply.data) {
                        let next = await projection.rearrange(arrangement)
                        guard self.client === client, !Task.isCancelled else { return }
                        snapshotSequence = coveredThrough
                        if reloadArrangement { arrangementSequence = arrangementCoveredThrough }
                        discardBeforeSnapshot()
                        lastError = nil
                        if let next {
                            tree = next
                            onTree?(next)
                        }
                        continue
                    }
                    let next = try await projection.reset(snapshot: reply.data, macID: macID,
                                                          previous: tree?.workspaces ?? [], agents: agents,
                                                          activity: activity, arrangement: arrangement)
                    guard self.client === client, !Task.isCancelled else { return }
                    if !macID.isEmpty { Self.noteHeld(await projection.known, macID: macID) }
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
        let next = await Task.detached { Self.arrangement(personal: personal, layout: layout) }.value
        // Bound to another Mac meanwhile: not this one's.
        guard self.client === client else { return }
        arrangement = next
    }

    /// The setup batch's requests before the arrangement's two (`prepare`).
    nonisolated static let setupCount = 5

    /// The Mac's order, groups, rooms and pins from `list-personal` and `sidebar_layout.get`
    /// replies; a missing or failed one leaves its part empty.
    nonisolated static func arrangement(personal: Data?, layout: Data?) -> SidebarArrangement {
        var next = SidebarArrangement()
        if let personal, let reply = try? check(personal) {
            next.rows = SidebarArrangement.rows(personal: reply)
            next.groups = SidebarArrangement.groups(personal: reply)
            next.rooms = SidebarArrangement.rooms(personal: reply)
            next.roomPins = SidebarArrangement.roomPins(personal: reply)
        }
        if let layout, let reply = try? checkResource(layout) {
            next.pins = SidebarArrangement.pins(layout: reply)
        }
        return next
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

    /// The daemon's capability for `known` on `list-workspaces`.
    nonisolated static let knownCapability = "list-workspaces-known-v1"

    /// `list-workspaces`' params: the held tree as `known` (`{}` before a revision) when the
    /// daemon takes it, else none. Built off the main actor so the dictionary starts in its own
    /// region and can be sent to the client.
    nonisolated static func listParams(known held: WorkspaceProjection.KnownTree?, sendsKnown: Bool) -> [String: Any] {
        guard sendsKnown else { return [:] }
        var known: [String: Any] = [:]
        if let held { known = held.params }
        return ["known": known]
    }

    /// The setup batch's `list-workspaces` params: `known` (`{}`) when the daemon takes it, and
    /// the first window's `limit` when it takes that (`ListFirstWindow`). A first window carries
    /// no `tree_revision`, so the `refresh()` after it sends `known: {}` and gets the whole tree.
    nonisolated static func setupListParams(sendsKnown: Bool, firstWindow: Bool) -> [String: Any] {
        listParams(known: nil, sendsKnown: sendsKnown).merging(ListFirstWindow.params(honors: firstWindow)) { $1 }
    }

    /// Whether `reply` is the daemon's `{"unchanged": true}` answer to a `known` (the held
    /// tree is current). Only a short line can be one, so a whole tree is not parsed twice.
    nonisolated static func isUnchanged(_ reply: Data) -> Bool {
        guard reply.count < 4096,
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              object["ok"] as? Bool != false else { return false }
        let data = object["data"] as? [String: Any] ?? object
        return data["unchanged"] as? Bool == true
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

// MARK: - One-request catch-up (`catch-up` link service)

extension WorkspaceSync {
    /// What the phone's `daemon` line lists in `set-client-info`; a `catch-up` lists the same
    /// for its own read, so its tree reads as this line's does.
    nonisolated static let clientCapabilities = ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"]

    /// Where a `catch-up` starts: the held tree's `known` and the line position its answer will
    /// cover (taken before the channel opens, as ``refresh()`` takes it before its list). Nil
    /// while the line sets up or lists, or on a daemon that does not take `known`: today's
    /// list answers then.
    func catchUpStart() async -> (known: WorkspaceProjection.KnownTree?, coveredThrough: UInt64)? {
        guard let client, !initializing, refreshTask == nil, listsKnown else { return nil }
        let known = await projection.known
        return (known, await client.receivedPosition)
    }

    /// Applies a `catch-up` reply's tree (`data`, the daemon's `list-workspaces` answer) as
    /// ``refresh()`` applies its own list's: `unchanged` keeps the tree and orders it again, a
    /// whole tree replaces it. False when it was not applied (a list ran meanwhile, the line
    /// changed): the caller lists as today.
    @discardableResult
    func applyCatchUp(_ data: Data, unchanged: Bool, coveredThrough: UInt64) async -> Bool {
        guard let client, !initializing, refreshTask == nil else { return false }
        let projection = projection
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            await updateTask?.value
            defer {
                if self.client === client {
                    refreshTask = nil
                    // A refresh() asked while this applied lists after it, as its own loop would.
                    if dirty {
                        dirty = false
                        Task { await self.refresh() }
                    } else {
                        drain()
                    }
                }
            }
            guard self.client === client, !Task.isCancelled else { return false }
            if unchanged {
                let next = await projection.rearrange(arrangement)
                guard self.client === client, !Task.isCancelled else { return false }
                snapshotSequence = max(snapshotSequence, coveredThrough)
                discardBeforeSnapshot()
                lastError = nil
                if let next {
                    tree = next
                    onTree?(next)
                }
                return true
            }
            do {
                let next = try await projection.reset(snapshot: data, macID: macID,
                                                      previous: tree?.workspaces ?? [], agents: agents,
                                                      activity: activity, arrangement: arrangement)
                guard self.client === client, !Task.isCancelled else { return false }
                snapshotSequence = max(snapshotSequence, coveredThrough)
                discardBeforeSnapshot()
                tree = next
                lastError = nil
                onTree?(next)
                return true
            } catch {
                log.error("catch-up tree: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        refreshTask = Task { _ = await task.value }
        return await task.value
    }
}
