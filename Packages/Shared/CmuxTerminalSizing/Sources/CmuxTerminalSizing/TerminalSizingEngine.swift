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
        var participant = participant
        // A decoded participant bypasses the clamping initializer.
        participant.viewport = participant.viewport?.clamped
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

    /// Forgets a viewport while keeping the view attached: a viewer that hid
    /// the terminal (an iPhone app in the background, a terminal off screen)
    /// stops counting until its next `report`. Twin of the Rust
    /// `clear_viewport`; fixture op `clear_viewport`.
    @discardableResult
    public mutating func clearViewport(_ id: String) -> Bool {
        guard let i = index(id) else { return false }
        entries[i].participant.viewport = nil
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
        // Defer only to a desktop of the same user that itself counts: a
        // viewer-only or viewport-less Mac leaves the phone in charge.
        return !entries.contains {
            let other = $0.participant
            return other.userID == user && other.deviceKind.isDesktop
                && other.viewport != nil && other.countsOverride != false
        }
    }

    /// A counting entry with its viewport unwrapped: `counts(_:)` refuses an
    /// entry without one, and the pair makes the type hold that.
    private struct Sized {
        var entry: Entry
        var viewport: TerminalGridSize
    }

    private func decide(_ counting: [Entry]) -> (TerminalGridSize, [String], TerminalSizingReason) {
        if policy.mode == .fixed, let fixed = policy.fixed {
            return (fixed, [], .fixed)
        }
        let sized = counting.compactMap { entry in
            entry.participant.viewport.map { Sized(entry: entry, viewport: $0) }
        }
        func newest(_ list: [Sized]) -> Sized? {
            list.max { $0.entry.activity < $1.entry.activity }
        }
        guard let latest = newest(sized) else { return (held, [], .held) }
        switch policy.mode {
        case .latest, .fixed:
            return (latest.viewport, [latest.entry.participant.id], .latest)
        case .priority:
            for key in policy.priority {
                let matches = sized.filter { $0.entry.participant.matchesPriorityKey(key) }
                if let owner = newest(matches) {
                    return (owner.viewport, [owner.entry.participant.id], .priority)
                }
            }
            return (latest.viewport, [latest.entry.participant.id], .priorityFallback)
        case .smallest, .largest:
            let pick: ([Int]) -> Int? = policy.mode == .smallest ? { $0.min() } : { $0.max() }
            guard let cols = pick(sized.map(\.viewport.cols)), let rows = pick(sized.map(\.viewport.rows)) else {
                return (held, [], .held)
            }
            let owners = sized
                .filter { $0.viewport.cols == cols || $0.viewport.rows == rows }
                .map(\.entry.participant.id)
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
