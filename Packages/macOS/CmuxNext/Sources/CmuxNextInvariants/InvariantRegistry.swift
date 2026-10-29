#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation
import os

/// The app's one invariant checker (plans/cmux-next/invariants-DESIGN.md): every perf mechanism and every focus,
/// geometry and ownership rule states its invariant once, as an ``InvariantRule`` its owner declares here, and the
/// registry checks it after the commit of each action and of each turn that touched state the rule reads
/// (``InvariantTurnObserver``). A violation goes once per signature into the append-only ``ledger``, which
/// `debug.invariants` serves and journeys and the fuzz fail on. Nothing here repairs state: a broken rule stays
/// visible and replayable. Debug and bench builds only; Release has no registry, no observer and no rule.
///
/// ```swift
/// let registry = InvariantRegistry(mode: InvariantMode(environment: environment)) { delay, work in
///     deadline.schedule(after: delay, work)
/// }
/// registry.declare(rule)
/// observer = InvariantTurnObserver(registry: registry)
/// ```
@MainActor
public final class InvariantRegistry {
    /// The actions a trigger names.
    public static let actionsKept = 8
    /// The run time a rule may take at p95, in microseconds; above it the rule is its own violation,
    /// `INV-COST@<id>` (section 4). The fix is a smaller scope, never a throttle.
    public static let costLimitMicros = 250.0
    /// The runs of a rule before its cost is judged.
    static let costMinimumRuns: UInt64 = 20

    public let mode: InvariantMode
    /// `app` or `daemon`: part of every signature.
    public let host: String
    public let ledger = InvariantLedger()
    /// Called once per new violation, after it is in the ledger, with the rule's whole read state (the ledger keeps
    /// at most ``InvariantViolation/stateLimit`` bytes of it): the app journals it and writes its report after the
    /// frame.
    public var onReport: ((InvariantViolation, Data?) -> Void)?
    public private(set) var rules: [InvariantRule] = []
    /// Passes run by turns (idle turns are not passes).
    public private(set) var turnsChecked: UInt64 = 0
    var records: [InvariantRuleRecord] = []
    var byID: [InvariantID: Int] = [:]
    var byKey: [InvariantKey: [Int]] = [:]
    var afterActionRules: [Int] = []
    var livenessRules: [Int] = []
    /// What this turn touched, by key.
    var touched: [InvariantKey: Set<InvariantSubject>] = [:]
    /// The actions of this turn.
    var turnActions: [InvariantActionCause] = []
    /// The last actions in any turn (a check's or an inline report's trigger names them).
    var recentActions: [InvariantActionCause] = []
    var actionCount: UInt64 = 0
    /// The liveness deadline fired: the next turn checks the liveness rules.
    var livenessDue = false
    var livenessDeadline: ContinuousClock.Instant?
    /// Rules reported as `INV-COST` and not yet back under the limit.
    var costReported: Set<Int> = []
    var turn: UInt64 = 0
    var passTiming = InvariantTiming()
    let now: @MainActor () -> ContinuousClock.Instant
    let schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "app.invariants")

    /// - Parameters:
    ///   - mode: Whether turns run the rules (``InvariantMode/init(environment:)``).
    ///   - host: `app` or `daemon`.
    ///   - now: The clock rule times and liveness waits read (tests pass their own).
    ///   - schedule: Runs its work once after its delay, replacing the work it was given before (the app's one
    ///     `MainDeadline` for the liveness rules).
    public init(mode: InvariantMode, host: String = "app",
                now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
                schedule: @escaping @MainActor (Duration, @escaping @MainActor () -> Void) -> Void) {
        self.mode = mode
        self.host = host
        self.now = now
        self.schedule = schedule
    }

    /// Whether turns run the rules.
    public var isArmed: Bool { mode.isArmed }

    /// Adds `rule`. A second rule with the same id, or an `.ipc` or `.census` rule at a per-turn check point, is a
    /// programming error: it stops a Debug build and is dropped elsewhere.
    public func declare(_ rule: InvariantRule) {
        guard byID[rule.id] == nil else {
            assertionFailure("invariant \(rule.id) is declared twice")
            return
        }
        guard rule.cost.mayRunPerTurn || rule.points.isDisjoint(with: [.afterAction, .afterTurn]) else {
            assertionFailure("invariant \(rule.id): a \(rule.cost.rawValue) rule runs only from the harness")
            return
        }
        let index = rules.count
        rules.append(rule)
        records.append(InvariantRuleRecord())
        byID[rule.id] = index
        if rule.points.contains(.afterTurn) {
            for key in rule.reads { byKey[key, default: []].append(index) }
        }
        if rule.points.contains(.afterAction) { afterActionRules.append(index) }
        if rule.isLiveness { livenessRules.append(index) }
    }

    /// The state under `key` changed for `subject`: the rules that read `key` run at the end of this turn.
    public func touch(_ key: InvariantKey, _ subject: InvariantSubject) {
        guard mode.isArmed else { return }
        touched[key, default: []].insert(subject)
    }

    /// An action is about to run (`ActionRegistry.willRunObservers`): the `.afterAction` rules run on this turn's
    /// commit, and a violation names it. Builds no string: `id` and `origin` are the action's own raw values.
    public func noteAction(_ id: String, origin: String) {
        actionCount += 1
        let cause = InvariantActionCause(id: id, origin: origin, index: actionCount)
        recentActions.append(cause)
        if recentActions.count > Self.actionsKept { recentActions = Array(recentActions.suffix(Self.actionsKept)) }
        guard mode.isArmed else { return }
        turnActions.append(cause)
        if turnActions.count > Self.actionsKept { turnActions = Array(turnActions.suffix(Self.actionsKept)) }
    }

    /// A call-site checker found `id` broken (``InvariantProbe/fail(_:_:_:fileID:line:)``): reported at once, every
    /// time, with trigger kind `inline`.
    public func fail(_ id: InvariantID, _ subject: InvariantSubject, _ detail: String,
                     fileID: StaticString = #fileID, line: UInt = #line) {
        guard mode.isArmed else { return }
        report(id: id, subject: subject, detail: detail, state: nil,
               trigger: InvariantTrigger(kind: .inline, actions: recentActions, turn: turn, fileID: "\(fileID)", line: line))
    }

    /// One rule's counts and run times, nil for an id nobody declared.
    public func stats(of id: InvariantID) -> InvariantRuleStats? {
        byID[id].map { InvariantRuleStats(records[$0]) }
    }

    /// Every pass's run time (the section 6 dirty-turn target).
    public var passStats: InvariantRuleStats { InvariantRuleStats(timing: passTiming) }

    /// Forgets which signatures were reported (`debug.invariants {clear: true}`), so a broken rule is reported again
    /// at its next run. The ledger's sequence numbers go on.
    public func clearReported() {
        for index in records.indices {
            records[index].reported = []
            records[index].suspected = []
        }
        costReported = []
    }

    /// Puts one violation in the ledger, logs it, hands it to ``onReport`` and, in trap mode, stops.
    func report(id: InvariantID, subject: InvariantSubject, detail: String, state: Data?, trigger: InvariantTrigger) {
        let kept = state.flatMap { $0.count <= InvariantViolation.stateLimit ? $0 : nil }
        let host = host
        let violation = ledger.append { seq in
            InvariantViolation(seq: seq, id: id, host: host, subject: subject, detail: detail, trigger: trigger, state: kept)
        }
        logger.fault("invariant \(id.rawValue, privacy: .public) \(subject.description, privacy: .public): \(detail, privacy: .public)")
        onReport?(violation, state)
        if mode == .trap {
            // crash-allow: trap mode is opt-in (CMUX_NEXT_INVARIANTS=trap, Debug and bench builds only) and asks to stop at the first violation
            fatalError("invariant \(id.rawValue) \(subject): \(detail) (CMUX_NEXT_INVARIANTS=trap)")
        }
    }
}
#endif
