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
    public nonisolated static let actionsKept = 8
    /// The run time a rule may take at p95, in microseconds; above it the rule is its own violation,
    /// `INV-COST@<id>` (section 4). The fix is a smaller scope, never a throttle.
    public nonisolated static let costLimitMicros = 250.0
    /// The run time a whole pass may take at p95, in microseconds (the `perf-hot` budget of ``runTurn()``, memo
    /// builds included); above it the pass is its own violation, `INV-COST@pass`.
    public nonisolated static let passLimitMicros = 1_000.0
    /// The runs of a rule (or passes) before its cost is judged.
    nonisolated static let costMinimumRuns: UInt64 = 20

    /// One violation new in this pass, with the rule's read state as the read gave it: the app journals it, and
    /// encodes the state with the report off the main thread.
    public struct NewViolation: Sendable {
        public let violation: InvariantViolation
        /// The rule's read state as sorted-key JSON; nil for an inline report. Call it off the main thread.
        public let state: @Sendable () -> Data?
    }

    public let mode: InvariantMode
    /// `app` or `daemon`: part of every signature.
    public let host: String
    public let ledger = InvariantLedger()
    /// Called once per pass that found new violations (and once per inline report), after they are in the ledger:
    /// the app journals them and writes one report for the batch after the frame, off the violating turn.
    public var onReports: (([NewViolation]) -> Void)?
    public private(set) var rules: [InvariantRule] = []
    /// Passes run by turns (idle turns are not passes).
    public internal(set) var turnsChecked: UInt64 = 0
    var records: [InvariantRuleRecord] = []
    var byID: [InvariantID: Int] = [:]
    var byKey: [InvariantKey: [Int]] = [:]
    var afterActionRules: [Int] = []
    var livenessRules: [Int] = []
    /// What this turn touched, by key.
    var touched: [InvariantKey: Set<InvariantSubject>] = [:]
    /// The actions of this turn.
    var turnActions = InvariantActionRing(capacity: InvariantRegistry.actionsKept)
    /// The last actions in any turn (a check's or an inline report's trigger names them).
    var recentActions = InvariantActionRing(capacity: InvariantRegistry.actionsKept)
    var actionCount: UInt64 = 0
    /// The liveness deadline fired: the next turn checks the liveness rules.
    var livenessDue = false
    var livenessDeadline: ContinuousClock.Instant?
    /// Rules reported as `INV-COST` and not yet back under the limit.
    var costReported: Set<Int> = []
    /// The pass was reported as `INV-COST@pass` and is not yet back under its limit.
    var passCostReported = false
    /// The violations of the running pass, handed to ``onReports`` together at its end.
    var unflushed: [NewViolation] = []
    var turn: UInt64 = 0
    var passTiming = InvariantTiming(limitMicros: InvariantRegistry.passLimitMicros)
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
    /// commit, and a violation names it. Builds no string and allocates nothing: `id` and `origin` are the action's
    /// own raw values, written into fixed rings.
    public func noteAction(_ id: String, origin: String) {
        actionCount += 1
        let cause = InvariantActionCause(id: id, origin: origin, index: actionCount)
        recentActions.append(cause)
        guard mode.isArmed else { return }
        turnActions.append(cause)
    }

    /// A call-site checker found `id` broken (``InvariantProbe/fail(_:_:_:fileID:line:)``): reported at once, every
    /// time, with trigger kind `inline`. Armed or not: a call-site check costs nothing until it fails, and an unarmed
    /// bench build still lists what its own checks caught.
    public func fail(_ id: InvariantID, _ subject: InvariantSubject, _ detail: String,
                     fileID: StaticString = #fileID, line: UInt = #line) {
        report(id: id, subject: subject, detail: detail, state: nil,
               trigger: InvariantTrigger(kind: .inline, actions: recentActions.ordered, turn: turn, fileID: "\(fileID)", line: line))
        flushReports()
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
        for index in records.indices { records[index].reported = [] }
        costReported = []
        passCostReported = false
    }

    /// Puts one violation in the ledger and logs it; ``flushReports()`` hands it to ``onReports`` with the rest of
    /// its pass.
    func report(id: InvariantID, subject: InvariantSubject, detail: String, state: (@Sendable () -> Data?)?,
                trigger: InvariantTrigger) {
        let host = host
        let violation = ledger.append { seq in
            InvariantViolation(seq: seq, id: id, host: host, subject: subject, detail: detail, trigger: trigger, state: nil)
        }
        logger.fault("invariant \(id.rawValue, privacy: .public) \(subject.description, privacy: .public): \(detail, privacy: .public)")
        unflushed.append(NewViolation(violation: violation, state: state ?? { nil }))
    }

    /// Hands the pass's new violations to ``onReports`` as one batch.
    func flushReports() {
        guard !unflushed.isEmpty else { return }
        let batch = unflushed
        unflushed = []
        onReports?(batch)
    }
}
#endif
