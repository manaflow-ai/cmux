/// Decides the PTY grid of one shared terminal. Pure and synchronous: the host
/// feeds attach, detach, viewport, activity, counts and policy events and
/// publishes `state` whenever a mutation returns `true`.
///
/// The Rust twin in cmux-tui-core must stay identical; both replay
/// `schemas/terminal-sizing/fixtures.json`.
public struct TerminalSizingEngine: Sendable {
    private struct Entry: Sendable {
        var participant: TerminalSizingParticipant
        var activity: UInt64
    }

    private var entries: [Entry] = []
    private var activityClock: UInt64 = 0
    private var policy: TerminalSizingPolicy
    private var held: TerminalGridSize
    public private(set) var state: TerminalSizingState

    /// - Parameters:
    ///   - initialSize: the grid before anyone reports, usually the PTY's current size.
    ///   - policy: the effective policy (workspace default or terminal override).
    public init(initialSize: TerminalGridSize, policy: TerminalSizingPolicy = .fitEveryone) {
        self.policy = policy
        self.held = initialSize.clamped
        self.state = TerminalSizingState(
            generation: 0, cols: held.cols, rows: held.rows, reason: .held,
            owners: [], policy: policy, participants: []
        )
    }

    // MARK: Mutations. Each returns true when the published state changed.

    /// Adds a view, or replaces one with the same id. Attach counts as activity.
    @discardableResult
    public mutating func attach(_ participant: TerminalSizingParticipant) -> Bool {
        activityClock += 1
        if let i = index(participant.id) {
            entries[i] = Entry(participant: participant, activity: activityClock)
        } else {
            entries.append(Entry(participant: participant, activity: activityClock))
        }
        return publish()
    }

    @discardableResult
    public mutating func detach(_ id: String) -> Bool {
        guard let i = index(id) else { return false }
        entries.remove(at: i)
        return publish()
    }

    @discardableResult
    public mutating func report(_ id: String, viewport: TerminalGridSize) -> Bool {
        guard let i = index(id) else { return false }
        entries[i].participant.viewport = viewport.clamped
        return publish()
    }

    /// Explicit focus-click or keyboard, paste or mouse input. Never hover.
    @discardableResult
    public mutating func noteActivity(_ id: String) -> Bool {
        guard let i = index(id) else { return false }
        activityClock += 1
        entries[i].activity = activityClock
        return publish()
    }

    @discardableResult
    public mutating func setCountsOverride(_ id: String, _ value: Bool?) -> Bool {
        guard let i = index(id) else { return false }
        entries[i].participant.countsOverride = value
        return publish()
    }

    @discardableResult
    public mutating func setPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        self.policy = policy
        return publish()
    }

    // MARK: Queries

    public func counts(_ id: String) -> Bool {
        guard let entry = entries.first(where: { $0.participant.id == id }) else { return false }
        return counts(entry)
    }

    public var participantIDs: [String] { entries.map(\.participant.id) }

    // MARK: Rules

    private func index(_ id: String) -> Int? {
        entries.firstIndex { $0.participant.id == id }
    }

    private func counts(_ entry: Entry) -> Bool {
        let p = entry.participant
        guard p.viewport != nil else { return false }
        if let explicit = p.countsOverride { return explicit }
        // Fit-everyone modes promise to count every attached view; the handheld
        // deferral only stops a phone from taking the grid by activity.
        if policy.mode == .smallest || policy.mode == .largest { return true }
        guard p.deviceKind.isHandheld, let user = p.userID else { return true }
        return !entries.contains {
            $0.participant.userID == user && ($0.participant.deviceKind == .mac || $0.participant.deviceKind == .tui)
        }
    }

    private func decide(_ counting: [Entry]) -> (TerminalGridSize, [String], TerminalSizingReason) {
        if policy.mode == .fixed, let fixed = policy.fixed {
            return (fixed, [], .fixed)
        }
        guard !counting.isEmpty else { return (held, [], .held) }
        func newest(_ list: [Entry]) -> Entry {
            list.max { $0.activity < $1.activity }!
        }
        switch policy.mode {
        case .latest, .fixed:
            let owner = newest(counting)
            return (owner.participant.viewport!, [owner.participant.id], .latest)
        case .priority:
            for key in policy.priority {
                let matches = counting.filter { $0.participant.priorityKey == key }
                if !matches.isEmpty {
                    let owner = newest(matches)
                    return (owner.participant.viewport!, [owner.participant.id], .priority)
                }
            }
            let owner = newest(counting)
            return (owner.participant.viewport!, [owner.participant.id], .priorityFallback)
        case .smallest, .largest:
            let pick: ([Int]) -> Int = policy.mode == .smallest ? { $0.min()! } : { $0.max()! }
            let cols = pick(counting.map { $0.participant.viewport!.cols })
            let rows = pick(counting.map { $0.participant.viewport!.rows })
            let owners = counting
                .filter { $0.participant.viewport!.cols == cols || $0.participant.viewport!.rows == rows }
                .map(\.participant.id)
            return (TerminalGridSize(cols: cols, rows: rows), owners, policy.mode == .smallest ? .smallest : .largest)
        }
    }

    private mutating func publish() -> Bool {
        let counting = entries.filter(counts)
        let (size, owners, reason) = decide(counting)
        if reason != .held && reason != .fixed { held = size }
        let rows = entries.map { TerminalSizingParticipantState(participant: $0.participant, counts: counts($0)) }
        var next = TerminalSizingState(
            generation: state.generation, cols: size.cols, rows: size.rows, reason: reason,
            owners: owners, policy: policy, participants: rows
        )
        guard next != state else { return false }
        next.generation = state.generation + 1
        state = next
        return true
    }
}
