#if os(iOS)
/// Pure policy for which welcome-tour stages present and in what order.
///
/// The plan is recomputed from live inputs on every container render, so a
/// stage whose prerequisite resolves mid-flow (sign-in completes, the system
/// notification prompt gets answered) simply drops out of the pipeline. The
/// container asks the plan where to go next relative to the stage on screen,
/// which keeps navigation correct even when the on-screen stage is no longer
/// part of the plan.
struct WelcomeStagePlan: Equatable {
    /// The stages to present, in presentation order. Never empty: `hello` and
    /// `connect` always participate, since the tour exists to demonstrate the
    /// product and link a Mac.
    let stages: [WelcomeStage]

    /// Builds the plan from the two live prerequisites.
    ///
    /// - Parameters:
    ///   - isAuthenticated: Whether an account session already exists; when
    ///     `true`, the sign-in stage is omitted.
    ///   - needsNotificationDecision: Whether the system notification prompt
    ///     has never been answered; when `false`, the opt-in stage is omitted.
    init(isAuthenticated: Bool, needsNotificationDecision: Bool) {
        var stages: [WelcomeStage] = [.hello]
        if needsNotificationDecision {
            stages.append(.notifications)
        }
        if !isAuthenticated {
            stages.append(.signIn)
        }
        stages.append(.connect)
        self.stages = stages
    }

    /// The stage the container should present when asked to show `stage`.
    ///
    /// A stage that left the plan (its prerequisite resolved while it was on
    /// screen) resolves to the next planned stage after its canonical
    /// position, so a completed sign-in flows forward into connect rather
    /// than bouncing backward.
    /// - Parameter stage: The stage currently on screen or requested.
    /// - Returns: `stage` itself when planned, otherwise the nearest planned
    ///   stage after it in canonical order.
    func resolved(_ stage: WelcomeStage) -> WelcomeStage {
        if stages.contains(stage) {
            return stage
        }
        let canonical = WelcomeStage.allCases
        guard let position = canonical.firstIndex(of: stage) else {
            return stages[0]
        }
        for candidate in canonical[position...] where stages.contains(candidate) {
            return candidate
        }
        return stages[stages.count - 1]
    }

    /// The first planned stage strictly after `stage` in canonical order, or
    /// `nil` when nothing follows.
    ///
    /// The scan uses canonical order, not plan membership, so advancing from a
    /// stage that just dropped out of the plan (its prerequisite resolved while
    /// it was on screen) lands on its true successor instead of skipping one.
    /// - Parameter stage: The stage being advanced from.
    /// - Returns: The next planned stage, or `nil` at the end.
    func next(after stage: WelcomeStage) -> WelcomeStage? {
        let canonical = WelcomeStage.allCases
        guard let position = canonical.firstIndex(of: stage) else {
            return nil
        }
        for candidate in canonical[canonical.index(after: position)...]
        where stages.contains(candidate) {
            return candidate
        }
        return nil
    }

    /// The planned stage before `stage`, or `nil` when `stage` is first.
    /// - Parameter stage: The stage on screen.
    /// - Returns: The previous stage in the plan, or `nil` at the start.
    func previous(before stage: WelcomeStage) -> WelcomeStage? {
        let current = resolved(stage)
        guard let index = stages.firstIndex(of: current), index > stages.startIndex else {
            return nil
        }
        return stages[stages.index(before: index)]
    }

    /// The zero-based position of `stage` within the plan, for progress dots.
    /// - Parameter stage: The stage on screen.
    /// - Returns: The index of the resolved stage in ``stages``.
    func position(of stage: WelcomeStage) -> Int {
        stages.firstIndex(of: resolved(stage)) ?? 0
    }
}
#endif
