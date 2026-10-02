public import AppKit
public import Observation

/// Where the pane's data comes from. The App fills it from the local CUA host
/// socket and, for other machines, the daemon relay; `AgentActivityMockSource`
/// fills it with demo data. A source pushes updates; it never polls.
@MainActor
public protocol AgentActivitySource: AnyObject {
    /// Starts pushing updates to `sink` (sessions first, then events).
    func start(_ sink: @escaping @MainActor (AgentActivityUpdate) -> Void)
    /// Asks for the events of `session` (pushed as `.events`) while the
    /// pane shows it; `false` stops them.
    func follow(session: String, _ on: Bool)
    /// Decoded pixels of a frame, or nil when unavailable.
    func image(for frame: AgentActivityFrameRef) async -> NSImage?
    /// Sends a user operation to the owning host.
    func perform(_ op: AgentActivityUserOp) async throws
}

/// One machine's group in the session list.
public struct AgentActivityMachineGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let connection: AgentActivityConnection
    public let sessions: [AgentActivitySession]
}

/// View model of the Agent activity pane: a projection of the CUA hosts'
/// sessions and events plus this client's view state (selection, scrub,
/// filter). Nothing here changes a session; user operations go to the source
/// and the pane updates when the host's update arrives.
@MainActor
@Observable
public final class AgentActivityModel {
    public private(set) var sessionsByMachine: [String: [AgentActivitySession]] = [:]
    public private(set) var machineNames: [String: String] = [:]
    public private(set) var connections: [String: AgentActivityConnection] = [:]
    public private(set) var eventsBySession: [String: [AgentActivityEvent]] = [:]
    /// The selected session (view state of this client).
    public private(set) var selectedSessionID: String?
    /// Seq of the event the scrubber is on; nil means "follow the newest".
    public private(set) var scrubSeq: UInt64?
    public var filter: String = ""
    public var watching: Set<String> = []
    /// Last error from a user operation, for the toolbar.
    public private(set) var lastOperationError: String?

    @ObservationIgnored private let source: any AgentActivitySource
    @ObservationIgnored private var followed: [String] = []
    @ObservationIgnored private var extraFollowed: Set<String> = []

    public init(source: any AgentActivitySource) {
        self.source = source
    }

    public func start() {
        source.start { [weak self] update in self?.apply(update) }
    }

    // MARK: Updates from the host

    public func apply(_ update: AgentActivityUpdate) {
        switch update {
        case let .sessions(machine, sessions):
            sessionsByMachine[machine] = sessions
            if let name = sessions.first?.machineName { machineNames[machine] = name }
            if connections[machine] == nil { connections[machine] = .connected }
            reconcileSelection()
        case let .events(session, events):
            var current = eventsBySession[session] ?? []
            let next = current.last.map { $0.seq + 1 } ?? 0
            current.append(contentsOf: events.filter { $0.seq >= next })
            eventsBySession[session] = current
        case let .connection(machine, state):
            connections[machine] = state
        }
    }

    // MARK: Derived state

    /// Machines in a stable order (this Mac first, then by name), each with
    /// its sessions filtered and sorted: live first, then newest activity.
    public var groups: [AgentActivityMachineGroup] {
        let machines = Set(sessionsByMachine.keys).union(connections.keys)
        return machines.sorted { lhs, rhs in
            let lname = machineNames[lhs] ?? lhs
            let rname = machineNames[rhs] ?? rhs
            if (lhs == Self.localMachine) != (rhs == Self.localMachine) { return lhs == Self.localMachine }
            return lname.localizedStandardCompare(rname) == .orderedAscending
        }.map { machine in
            let sessions = (sessionsByMachine[machine] ?? [])
                .filter { Self.matches($0, filter: filter) }
                .sorted(by: Self.listOrder)
            return AgentActivityMachineGroup(
                id: machine, name: machineNames[machine] ?? machine,
                connection: connections[machine] ?? .connected, sessions: sessions)
        }
    }

    /// Machine id the App uses for this Mac.
    public static let localMachine = "local"

    public var allSessions: [AgentActivitySession] { sessionsByMachine.values.flatMap(\.self) }

    /// Live sessions on this Mac, for the titlebar indicator.
    public var liveLocalCount: Int {
        (sessionsByMachine[Self.localMachine] ?? []).filter(\.status.isLive).count
    }

    public var selectedSession: AgentActivitySession? {
        guard let selectedSessionID else { return nil }
        return allSessions.first { $0.id == selectedSessionID }
    }

    public var selectedEvents: [AgentActivityEvent] {
        guard let selectedSessionID else { return [] }
        return eventsBySession[selectedSessionID] ?? []
    }

    /// The event under the scrubber (the newest when following).
    public var currentEvent: AgentActivityEvent? {
        let events = selectedEvents
        guard let scrubSeq else { return events.last }
        return events.first { $0.seq == scrubSeq } ?? events.last
    }

    /// The frame to show for the scrubber position: the current event's, else
    /// the closest earlier event that has one.
    public var currentFrameEvent: AgentActivityEvent? {
        let events = selectedEvents
        guard let current = currentEvent, let index = events.firstIndex(of: current) else { return nil }
        return events[...index].last { $0.displayFrame != nil }
    }

    /// Whether the scrubber follows new events.
    public var isFollowingNewest: Bool { scrubSeq == nil }

    // MARK: View state (user actions in this client)

    public func select(session id: String?) {
        guard id != selectedSessionID else { return }
        selectedSessionID = id
        scrubSeq = nil
        updateFollow()
    }

    /// Moves the scrubber to `seq` (nil follows the newest event).
    public func scrub(to seq: UInt64?) {
        guard let seq, let last = selectedEvents.last, seq != last.seq else {
            scrubSeq = nil
            return
        }
        scrubSeq = selectedEvents.contains { $0.seq == seq } ? seq : nil
    }

    /// Steps the scrubber by `delta` events (`framesOnly` skips events
    /// without pixels).
    public func step(_ delta: Int, framesOnly: Bool = false) {
        let events = framesOnly ? selectedEvents.filter { $0.displayFrame != nil } : selectedEvents
        guard !events.isEmpty, delta != 0, let currentSeq = currentEvent?.seq else { return }
        let target: Int
        if let index = events.firstIndex(where: { $0.seq == currentSeq }) {
            target = index + delta
        } else if delta > 0 {
            guard let next = events.firstIndex(where: { $0.seq > currentSeq }) else { return }
            target = next + delta - 1
        } else {
            guard let previous = events.lastIndex(where: { $0.seq < currentSeq }) else { return }
            target = previous + delta + 1
        }
        scrub(to: events[min(max(target, 0), events.count - 1)].seq)
    }

    public func scrubToStart() { scrub(to: selectedEvents.first?.seq) }
    public func scrubToEnd() { scrub(to: nil) }

    // MARK: User operations (sent to the host; no optimistic change)

    public func perform(_ op: AgentActivityUserOp) {
        if case let .watch(session, on) = op {
            if on { watching.insert(session) } else { watching.remove(session) }
        }
        Task { @MainActor [source] in
            do {
                try await source.perform(op)
                self.lastOperationError = nil
            } catch {
                self.lastOperationError = String(describing: error)
            }
        }
    }

    public func image(for frame: AgentActivityFrameRef) async -> NSImage? {
        await source.image(for: frame)
    }

    // MARK: Rules (pure, tested)

    static func matches(_ session: AgentActivitySession, filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        let haystack = [session.label, session.agentName, session.agentKind, session.workspaceTitle ?? "",
                        session.terminalTitle ?? "", session.machineName] + session.targetApps
        return haystack.contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    static func listOrder(_ lhs: AgentActivitySession, _ rhs: AgentActivitySession) -> Bool {
        if lhs.status.isLive != rhs.status.isLive { return lhs.status.isLive }
        if lhs.lastActionAt != rhs.lastActionAt { return lhs.lastActionAt > rhs.lastActionAt }
        return lhs.id < rhs.id
    }

    /// Keeps the selection while its session exists; otherwise selects the
    /// first live session, else the first session, else nothing.
    private func reconcileSelection() {
        let all = allSessions
        if let selectedSessionID, all.contains(where: { $0.id == selectedSessionID }) { return }
        let first = groups.flatMap(\.sessions).first
        selectedSessionID = first?.id
        scrubSeq = nil
        updateFollow()
    }

    /// Also follows `ids` (the lanes and grid layouts show every session's
    /// newest frame). The selection is always followed.
    public func follow(_ ids: Set<String>) {
        extraFollowed = ids
        updateFollow()
    }

    private func updateFollow() {
        var desired = extraFollowed.sorted()
        if let selectedSessionID, !extraFollowed.contains(selectedSessionID) { desired.append(selectedSessionID) }
        for id in followed where !desired.contains(id) { source.follow(session: id, false) }
        for id in desired where !followed.contains(id) { source.follow(session: id, true) }
        followed = desired
    }
}
