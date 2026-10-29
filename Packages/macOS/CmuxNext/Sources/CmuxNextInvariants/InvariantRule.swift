#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

/// One declared invariant (plans/cmux-next/invariants-DESIGN.md section 2.2): a `read` part that gives typed state
/// from the live app, and a pure `check` part over that state, so a unit test calls `check` on hand-built state
/// (`check` runs on the main actor with `read`, so it may call the owner's pure static helpers).
/// `read` returns nil when the rule does not apply now: that precondition is level state (a live resize, a drag in
/// flight, a request with a sequence number in flight), never a timer. The owner declares its rules next to its own
/// code, in `<Owner>+Invariants.swift` or its debug file, inside `#if DEBUG || CMUX_BENCH_HOOKS`.
///
/// ```swift
/// registry.declare(InvariantRule(
///     id: "DP1", statement: "every tab strip shows exactly its pane's tabs", owner: "TabDrag",
///     reads: [.tabs, .presentation], points: [.afterAction, .afterTurn], cost: .walk, parity: false,
///     read: { pass in session.hasDragInFlight ? nil : strips() },
///     check: { strips in strips.filter { $0.shown != $0.held }.map { InvariantFinding(subject: .pane($0.pane), detail: "...") } }))
/// ```
@MainActor
public struct InvariantRule {
    public let id: InvariantID
    /// The rule in one sentence, as the catalog states it.
    public let statement: String
    public let owner: String
    /// The keys whose touch makes the rule due at `.afterTurn`.
    public let reads: Set<InvariantKey>
    public let points: InvariantCheckPoints
    public let cost: InvariantCost
    /// Whether the read state goes into the R4 parity snapshot (`debug.invariants {state: true}`): false for state
    /// with clock values or generated ids.
    public let parity: Bool
    /// Why the rule is not in its final form yet (`rules[].interim`), nil for a final rule.
    public let interim: String?
    /// A finding is reported only when the rule's next run finds it again (the interim confirm of an async peer
    /// with no in-flight ledger yet; section 7 step 2). Never a timer: the next run is the next check point.
    public let confirmsAtNextCheck: Bool
    let body: Body

    enum Body {
        case state(@MainActor (InvariantPass) -> Evaluation?)
        case liveness(limit: Duration, pending: @MainActor (InvariantPass) -> [InvariantPending])
        case harness(@MainActor (InvariantPass) async -> Evaluation?)
    }

    /// One run's findings and, on demand, its read state as JSON.
    struct Evaluation {
        let findings: [InvariantFinding]
        let state: () -> Data?
    }

    /// A state rule, checked at `points` (`.afterAction`, `.afterTurn`; a `.harness` rule is
    /// ``harness(id:statement:owner:cost:parity:interim:read:check:)``).
    public init<State: Encodable & Equatable>(
        id: InvariantID, statement: String, owner: String,
        reads: Set<InvariantKey>, points: InvariantCheckPoints, cost: InvariantCost,
        parity: Bool = true, interim: String? = nil, confirmsAtNextCheck: Bool = false,
        read: @escaping @MainActor (InvariantPass) -> State?,
        check: @escaping @MainActor (State) -> [InvariantFinding]
    ) {
        self.init(id: id, statement: statement, owner: owner, reads: reads, points: points, cost: cost, parity: parity,
                  interim: interim, confirmsAtNextCheck: confirmsAtNextCheck, body: .state({ pass in
                      guard let state = read(pass) else { return nil }
                      return Evaluation(findings: check(state), state: { InvariantRule.encode(state) })
                  }))
    }

    /// A liveness rule (section 3.4), the only timed kind: a subject `pending` returns that is still pending `limit`
    /// after its `since` is a violation. It only reports, and never changes state. The registry checks it whenever a
    /// key in `reads` is touched or an action ran, and once more at the earliest limit (one deadline for all
    /// liveness rules), so no input need come.
    public static func liveness(
        id: InvariantID, statement: String, owner: String, reads: Set<InvariantKey>, limit: Duration,
        cost: InvariantCost = .cheap, interim: String? = nil,
        pending: @escaping @MainActor (InvariantPass) -> [InvariantPending]
    ) -> InvariantRule {
        InvariantRule(id: id, statement: statement, owner: owner, reads: reads, points: [.afterAction, .afterTurn],
                      cost: cost, parity: false, interim: interim, confirmsAtNextCheck: false,
                      body: .liveness(limit: limit, pending: pending))
    }

    /// A harness rule (section 3.5): an IPC or census read, run only from `debug.invariants {check: true, ipc: true}`
    /// and never inside a turn. `read` may await another process; `check` stays pure.
    public static func harness<State: Encodable & Equatable>(
        id: InvariantID, statement: String, owner: String, cost: InvariantCost,
        parity: Bool = true, interim: String? = nil,
        read: @escaping @MainActor (InvariantPass) async -> State?,
        check: @escaping @MainActor (State) -> [InvariantFinding]
    ) -> InvariantRule {
        InvariantRule(id: id, statement: statement, owner: owner, reads: [], points: .harness, cost: cost, parity: parity,
                      interim: interim, confirmsAtNextCheck: false, body: .harness({ pass in
                          guard let state = await read(pass) else { return nil }
                          return Evaluation(findings: check(state), state: { InvariantRule.encode(state) })
                      }))
    }

    private init(id: InvariantID, statement: String, owner: String, reads: Set<InvariantKey>,
                 points: InvariantCheckPoints, cost: InvariantCost, parity: Bool, interim: String?,
                 confirmsAtNextCheck: Bool, body: Body) {
        self.id = id
        self.statement = statement
        self.owner = owner
        self.reads = reads
        self.points = points
        self.cost = cost
        self.parity = parity
        self.interim = interim
        self.confirmsAtNextCheck = confirmsAtNextCheck
        self.body = body
    }

    /// Whether the rule is a liveness rule.
    public var isLiveness: Bool {
        if case .liveness = body { return true }
        return false
    }

    /// Canonical JSON of a read state: sorted keys, so equal states give equal bytes (the R4 diff).
    static func encode(_ state: some Encodable) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(state)
    }
}
#endif
