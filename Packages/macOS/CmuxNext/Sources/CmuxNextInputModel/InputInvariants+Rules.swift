#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextInvariants

// The input rules as the invariant registry declares them (plans/cmux-next/invariants-DESIGN.md, input-spec.md
// section 4): every rule reads one world check per pass, which the App memoizes over its live observation, and the
// rules themselves are pure over that result, so a test declares them over a hand-built observation.
extension InputInvariants {
    /// How long a window's focused pane may present another tab than the one the model targets (W9): about 12
    /// display frames.
    public static let presentationLimit: Duration = .milliseconds(200)
    /// How long a focus expectation may wait to land (W11): the creation hold (`CreationInputCoordinator.holdLimit`,
    /// 2 s), the longest the keys typed meanwhile are held for it, plus W9's wait for the presentation.
    public static let expectationLimit: Duration = .seconds(2) + presentationLimit

    /// The rules over one world check per pass (`world`, memoized by the caller): F1-F8, W1-W3, W5-W8 and W10 after
    /// each action and each touched turn; W4 at the harness check point (it compares the model with Chromium's focus,
    /// which an async reply sets: until an in-flight ledger names that wait as level state, it is checked only where
    /// the harness already waited, after a journey step); `INV-UNDECLARED` for an id the world check reports that no
    /// rule declares (never dropped); and the liveness rule W9 over the windows the check skipped as unsettled. The
    /// state names windows and panes, so none of them is a parity rule.
    @MainActor
    public static func declaredRules(world: @escaping @MainActor (InvariantPass) -> WorldResult?) -> [InvariantRule] {
        var rules = worldRules.map { invariant in
            let chromium = invariant == .chromiumMatches
            return InvariantRule(
                id: InvariantID(rawValue: invariant.rawValue), statement: invariant.summary, owner: "InputVerification",
                reads: [.focus, .presentation, .paneFrame], points: chromium ? .harness : [.afterAction, .afterTurn],
                cost: .walk, parity: false,
                interim: chromium ? "harness only (after each journey step) until the Chromium focus in-flight ledger exists" : nil,
                read: world,
                check: { result in result.violations.filter { $0.invariant == invariant }.map(finding) })
        }
        let declared = Set(worldRules)
        rules.append(InvariantRule(
            id: "INV-UNDECLARED", statement: "every id the world check reports is a declared rule", owner: "InputVerification",
            reads: [.focus, .presentation, .paneFrame], points: [.afterAction, .afterTurn], cost: .cheap, parity: false,
            read: world,
            check: { result in
                result.violations.filter { !declared.contains($0.invariant) }.map {
                    InvariantFinding(subject: $0.window.map(InvariantSubject.window) ?? .app,
                                     detail: "\($0.invariant.rawValue) is not declared (InputInvariants.worldRules): \($0.detail)")
                }
            }))
        rules.append(.liveness(
            id: InvariantID(rawValue: InputInvariant.presentationSettles.rawValue), statement: InputInvariant.presentationSettles.summary,
            owner: "InputVerification", reads: [.focus, .presentation], limit: presentationLimit) { pass in
                (world(pass)?.unsettled ?? []).map {
                    InvariantPending(subject: .window($0), detail: "the focused pane does not present the targeted tab")
                }
            })
        return rules
    }

    /// W11 (focus-invariant.md) as the registry runs it: a window's focus expectation still pending `limit` after its
    /// clock started (`FocusExpectationAges`: one expectation keeps its clock across a re-key; a window whose keys
    /// wait in a create's hold starts it when the hold ends). `read` gives the windows and the holding ones, nil when
    /// there is nothing to read.
    @MainActor
    public static func expectationRule(
        limit: Duration = expectationLimit,
        read: @escaping @MainActor (InvariantPass) -> (windows: [InputObservation.Window], holding: Set<String>)?
    ) -> InvariantRule {
        let clocks = ExpectationClocks()
        return .liveness(
            id: InvariantID(rawValue: InputInvariant.expectationLands.rawValue), statement: InputInvariant.expectationLands.summary,
            owner: "InputVerification", reads: [.focus, .presentation], limit: limit) { pass in
                guard let input = read(pass) else { return [] }
                return clocks.ages.pending(input.windows, now: pass.now, holding: input.holding).map {
                    InvariantPending(subject: .window($0.window), since: $0.since, detail: $0.detail)
                }
            }
    }

    /// One input violation as a registry finding: about its window, or the app.
    public static func finding(_ violation: InputViolation) -> InvariantFinding {
        InvariantFinding(subject: violation.window.map(InvariantSubject.window) ?? .app, detail: violation.detail)
    }
}

/// W11's clock per window, kept by its rule (``InputInvariants/expectationRule(limit:read:)``).
@MainActor
private final class ExpectationClocks {
    var ages = FocusExpectationAges()
}

/// The windows of the last pass's observation, reused by the next pass for every window no touched key names:
/// the invariant pass rebuilds only the windows a turn touched, the key window and the active one, and all of them
/// after an action, at a liveness limit or on a check (`dirty` nil).
@MainActor
public final class InputObservationReuse {
    private var kept: [String: InputObservation.Window] = [:]

    public init() {}

    /// The kept observation of window `id` when it may be reused: it is not in `dirty` (nil: every window is) and
    /// not in `pinned`.
    public func window(_ id: String, dirty: Set<String>?, pinned: Set<String>) -> InputObservation.Window? {
        guard let dirty, !dirty.contains(id), !pinned.contains(id) else { return nil }
        return kept[id]
    }

    /// Keeps `observation`'s windows for the next pass.
    public func keep(_ observation: InputObservation) {
        kept = Dictionary(observation.windows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
}
#endif
