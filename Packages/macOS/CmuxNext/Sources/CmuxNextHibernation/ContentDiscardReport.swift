/// The discard planner's last inputs for each content its owners report, as `debug.discards` shows
/// them: chrome://discards (chrome/browser/ui/webui/discards/discards_ui.cc) for every
/// ``ContentKind``. Per content: whether it shows, how long it has been hidden, its lifecycle state,
/// whether it can be discarded and why not (``DiscardEligibility``), its last discard's reason and how
/// often it woke. Owners report events at the point they decide; nothing here walks the session, and
/// reading the rows is O(contents tracked).
package nonisolated struct ContentDiscardReport: Sendable {
    /// A content's lifecycle state (Chrome's `LifecycleUnitState`: active, frozen, discarded).
    package nonisolated enum State: String, Hashable, Sendable {
        case live, frozen, discarded
    }

    /// What an owner reports about content `key`.
    package nonisolated enum Event: Hashable, Sendable {
        /// It shows. A verdict made while it was hidden no longer applies, and discarded content that
        /// shows was rebuilt (a wake; an agent page builds its page anew only to show it).
        case shown(String, ContentKind)
        /// It stopped showing.
        case hidden(String, ContentKind)
        /// Its owner judged it, counting it hidden for `hiddenFor` seconds (the owner's clock wins:
        /// an agent's call restarts it).
        case planned(String, ContentKind, hiddenFor: Double, DiscardEligibility)
        /// The owner discards it now for a reason; `discarded` completes it.
        case discarding(String, ContentKind, DiscardReason)
        /// The discard `discarding` started is done.
        case discarded(String)
        /// Discarded content was rebuilt, shown or not (a browser page restores in the background too).
        case woke(String)
        /// Live content froze (true) or thawed (false).
        case frozen(String, Bool)
        /// It closed.
        case removed(String)
    }

    /// One content as `debug.discards` shows it.
    package nonisolated struct Row: Equatable, Sendable {
        package var key: String
        package var kind: ContentKind
        package var visible: Bool
        /// Seconds since it was last visible; nil while it shows.
        package var hiddenFor: Double?
        package var state: State
        package var eligibility: DiscardEligibility
        /// Why it was last discarded; nil when it never was.
        package var lastDiscardReason: DiscardReason?
        /// Times it was rebuilt after a discard.
        package var wakeCount: Int
    }

    /// One kind as `debug.discards` shows it: whether an owner reports its contents, and how many.
    package nonisolated struct KindSummary: Equatable, Sendable {
        package var kind: ContentKind
        package var tracked: Bool
        package var contents: Int
        package var discarded: Int
        /// Why none of its contents is discarded: no owner discards this kind yet (Chrome's
        /// `kNotATab`); nil when an owner reports it.
        package var reason: CannotDiscardReason? { tracked ? nil : .notATab }
    }

    private nonisolated struct Input: Sendable {
        var kind: ContentKind
        var visible = false
        var hiddenSince: ContinuousClock.Instant?
        var state = State.live
        var verdict: DiscardEligibility?
        var pendingDiscard: DiscardReason?
        var lastDiscardReason: DiscardReason?
        var wakeCount = 0
    }

    private var inputs: [String: Input] = [:]
    /// The kinds an owner reports.
    package private(set) var trackedKinds: Set<ContentKind> = []

    package init() {}

    /// A report whose owners report the contents of `kinds`.
    package init(tracking kinds: ContentKind...) {
        trackedKinds = Set(kinds)
    }

    /// An owner reports the contents of `kind` from now on.
    package mutating func track(_ kind: ContentKind) {
        trackedKinds.insert(kind)
    }

    /// Applies an owner's report at `now`.
    package mutating func note(_ event: Event, at now: ContinuousClock.Instant) {
        switch event {
        case .shown(let key, let kind):
            update(key, kind) {
                if $0.state == .discarded { ($0.state, $0.wakeCount) = (.live, $0.wakeCount + 1) }
                ($0.visible, $0.hiddenSince, $0.verdict, $0.pendingDiscard) = (true, nil, nil, nil)
            }
        case .hidden(let key, let kind):
            update(key, kind) {
                ($0.visible, $0.hiddenSince, $0.verdict, $0.pendingDiscard) = (false, now, nil, nil)
            }
        case .planned(let key, let kind, let hiddenFor, let verdict):
            update(key, kind) {
                $0.visible = false
                $0.hiddenSince = now - .seconds(hiddenFor.isFinite ? max(hiddenFor, 0) : 0)
                $0.verdict = verdict
            }
        case .discarding(let key, let kind, let reason):
            update(key, kind) { $0.pendingDiscard = reason }
        case .discarded(let key):
            guard var input = inputs[key] else { return }
            input.state = .discarded
            input.lastDiscardReason = input.pendingDiscard ?? input.lastDiscardReason
            input.pendingDiscard = nil
            input.verdict = nil
            inputs[key] = input
        case .woke(let key):
            guard var input = inputs[key], input.state == .discarded else { return }
            input.state = .live
            input.wakeCount += 1
            inputs[key] = input
        case .frozen(let key, let isFrozen):
            guard var input = inputs[key], input.state != .discarded else { return }
            input.state = isFrozen ? .frozen : .live
            inputs[key] = input
        case .removed(let key):
            inputs[key] = nil
        }
    }

    /// The verdicts of one planner pass over `candidates`, from this pass only: a candidate the
    /// plan kept has the plan's reason; one the page probe kept lately (`recentlyKept`) and that is
    /// not due again keeps the probe's reason from `probeKept`; every other candidate is eligible
    /// (the due ones go now, the rest wait for their deadline).
    ///
    /// - Parameters:
    ///   - plan: The pass's plan.
    ///   - candidates: What the pass judged.
    ///   - probeKept: Why the page probe last kept each content.
    ///   - now: The pass's clock reading.
    package mutating func notePass(_ plan: ContentDiscardPlanner.Plan, candidates: [ContentDiscardPlanner.Candidate],
                                   probeKept: [String: CannotDiscardReason], at now: ContinuousClock.Instant) {
        let due = Set(plan.due)
        for candidate in candidates {
            var verdict = DiscardEligibility()
            if let reason = plan.exemptions[candidate.key] {
                verdict = DiscardEligibility(keptFor: reason)
            } else if candidate.recentlyKept, !due.contains(candidate.key), let reason = probeKept[candidate.key] {
                verdict = DiscardEligibility(keptFor: reason)
            }
            note(.planned(candidate.key, candidate.kind, hiddenFor: candidate.hiddenFor, verdict), at: now)
        }
    }

    /// Every reported content at `now`, ordered by key.
    package func rows(now: ContinuousClock.Instant) -> [Row] {
        inputs.map { Self.row($0.key, $0.value, now: now) }.sorted { $0.key < $1.key }
    }

    /// Content `key` at `now`; nil when no owner reported it.
    package func row(_ key: String, now: ContinuousClock.Instant) -> Row? {
        inputs[key].map { Self.row(key, $0, now: now) }
    }

    /// Each of the nine kinds, in declaration order.
    package var kinds: [KindSummary] {
        var contents: [ContentKind: Int] = [:]
        var discarded: [ContentKind: Int] = [:]
        for input in inputs.values {
            contents[input.kind, default: 0] += 1
            if input.state == .discarded { discarded[input.kind, default: 0] += 1 }
        }
        return ContentKind.allCases.map {
            KindSummary(kind: $0, tracked: trackedKinds.contains($0), contents: contents[$0] ?? 0, discarded: discarded[$0] ?? 0)
        }
    }

    private static func row(_ key: String, _ input: Input, now: ContinuousClock.Instant) -> Row {
        Row(key: key, kind: input.kind, visible: input.visible,
            hiddenFor: input.visible ? nil : input.hiddenSince.map { seconds(now - $0) },
            state: input.state, eligibility: eligibility(input),
            lastDiscardReason: input.lastDiscardReason, wakeCount: input.wakeCount)
    }

    /// Chrome's order (discard_eligibility_policy.cc `CanDiscard`): discarded content is
    /// disallowed, then visible content is protected, then the owner's last verdict applies. Hidden
    /// content no owner judged since it hid counts as just shown (Chrome's `kRecentlyVisible`).
    private static func eligibility(_ input: Input) -> DiscardEligibility {
        if input.state == .discarded { return DiscardEligibility(result: .disallowed, reasons: [.alreadyDiscarded]) }
        if input.visible { return DiscardEligibility(result: .protected, reasons: [.visible]) }
        return input.verdict ?? DiscardEligibility(result: .protected, reasons: [.recentlyVisible])
    }

    private mutating func update(_ key: String, _ kind: ContentKind, _ change: (inout Input) -> Void) {
        var input = inputs[key] ?? Input(kind: kind)
        input.kind = kind
        change(&input)
        inputs[key] = input
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

nonisolated extension DiscardEligibility {
    /// Content an owner keeps for `reason`, as strongly as the rule with that reason keeps it
    /// (``DiscardRule/registered``: `unsupported` and `form_submission` are disallowed); a reason no
    /// rule has (the page probe's, `neighbor`, `agent_driving`) protects it.
    ///
    /// - Parameters:
    ///   - reason: Why the owner keeps the content.
    ///   - rules: The planner's rules.
    package init(keptFor reason: CannotDiscardReason, rules: [DiscardRule] = DiscardRule.registered) {
        self.init(result: rules.first { $0.reason == reason }?.result ?? .protected, reasons: [reason])
    }
}
