/// Pure branch arbiter for the window's Bonsplit tab-close witness
/// (`splitTabBar(_:shouldCloseTab:inPane:)`).
///
/// The witness used to thread a fixed `if`/`else` cascade through the live
/// effects of each close branch. This type owns only the cascade: it maps the
/// witness's already-gathered booleans to the single ``TabCloseDecision`` the
/// witness should act on, preserving the legacy precedence order exactly. It
/// performs no I/O and holds no state, so the witness keeps ownership of every
/// side effect (the `NSAlert`/`confirmClosePanel` sheet, `NSSound.beep`, the
/// `bonsplitController.closeTab` mutation, the `remoteTmuxController` calls, the
/// `DispatchQueue`/`Task` scheduling, and the close-history push).
///
/// It carries no dependencies and is constructed at the call site
/// (`TabCloseDecisionCoordinator()`), mirroring the sibling
/// ``LastSurfaceWorkspaceClosePolicy``: the decision is a pure function of its
/// inputs.
public struct TabCloseDecisionCoordinator: Sendable {
    /// Creates the coordinator.
    public init() {}

    /// Selects the close branch for one tab-close request.
    ///
    /// Reproduces the legacy cascade's precedence exactly. Each input is the
    /// witness's resolution of the corresponding legacy guard, already folding
    /// in nil collaborators (a nil tab manager makes `isConfirmationInFlight`
    /// false; a missing panel makes `isPinned` false). `requiresConfirmation`
    /// is only consulted once `hasPanel` is true, after the no-panel branch has
    /// been ruled out, matching the legacy order where the confirmation policy
    /// ran after the `guard let panelId` bind.
    ///
    /// - Parameters:
    ///   - isRemoteTmuxRoute: the tab mirrors a remote tmux window with a live
    ///     mirror connection and is not a programmatic close (the legacy
    ///     `isRemoteTmuxMirror && !forceClose && panelId != nil &&
    ///     remoteTmuxController != nil && cachedMirrorTabActivity != nil`).
    ///   - isForceClose: the tab is in `forceCloseTabIds`.
    ///   - isConfirmationInFlight: a close confirmation is already in flight for
    ///     the resolved tab manager.
    ///   - isPinned: the closing tab maps to a pinned panel.
    ///   - closesWorkspaceOnLastSurface: an explicit user close that closes the
    ///     workspace's last surface (the legacy `explicitUserClose &&
    ///     shouldCloseWorkspaceOnLastSurface`).
    ///   - hasPanel: the closing tab maps to a panel.
    ///   - requiresConfirmation: the panel requires close confirmation (only
    ///     meaningful when `hasPanel`).
    public func decide(
        isRemoteTmuxRoute: Bool,
        isForceClose: Bool,
        isConfirmationInFlight: Bool,
        isPinned: Bool,
        closesWorkspaceOnLastSurface: Bool,
        hasPanel: Bool,
        requiresConfirmation: Bool
    ) -> TabCloseDecision {
        if isRemoteTmuxRoute { return .routeRemoteTmuxKill }
        if isForceClose { return .pushHistoryAndAllow }
        if isConfirmationInFlight { return .vetoInFlight }
        if isPinned { return .beepAndVetoPinned }
        if closesWorkspaceOnLastSurface { return .closeWorkspaceOnLastSurface }
        if !hasPanel { return .allowImmediate }
        if requiresConfirmation { return .confirmThenForce }
        return .pushHistoryAndAllow
    }
}
