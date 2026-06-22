/// The pure decision for what to do with the *source* workspace after a surface
/// is moved out of it into its own new workspace.
///
/// When the "move tab to new workspace" flow (the drop shim and its sibling
/// cross-window move) detaches the last surface from a workspace, the now-empty
/// source workspace must be cleaned up. The legacy app-target logic on
/// `AppDelegate` decided between three outcomes from live app state: if the
/// source workspace still has surfaces, do nothing; if it is empty but its
/// window holds other workspaces, close just that workspace; if it is the
/// window's only workspace, close the whole window. Those *effects* reach
/// `Workspace`/`TabManager`/`NSWindow` (app types that cannot leave the
/// executable target), so they stay in the thin app-side shim. The irreducible
/// *decision* between the three outcomes is pure boolean/count logic, so it
/// lives here as a value-typed policy returning a typed ``Outcome`` the shim
/// switches on. This mirrors ``DetachedWorkspaceTitlePolicy``: lift only the
/// decision, keep the live-state reach app-side.
///
/// The policy is a `Sendable` value type with one pure method and no stored
/// state, so it is trivially unit-testable and names no app types.
public struct DetachedSourceWorkspaceCleanupPolicy: Sendable, Equatable {
    /// What the app shim should do with the source workspace after a surface
    /// moved out of it.
    public enum Outcome: Sendable, Equatable {
        /// Leave the source workspace untouched. Returned when the source
        /// workspace still has surfaces, or it is no longer present in its
        /// window's workspace list (it was already removed elsewhere).
        case none
        /// Close just the (now-empty) source workspace, because its window still
        /// holds other workspaces.
        case closeWorkspace
        /// Close the whole source window, because the empty source workspace was
        /// that window's only workspace.
        case closeWindow
    }

    /// Creates the policy. It is stateless; the app constructs one wherever it
    /// cleans up an emptied source workspace.
    public init() {}

    /// Decides what to do with the source workspace after a surface moved out.
    ///
    /// - Parameters:
    ///   - sourceWorkspaceIsEmpty: Whether the source workspace has no remaining
    ///     surfaces (`Workspace.panels.isEmpty` app-side).
    ///   - sourceWorkspaceStillInManager: Whether the source workspace is still
    ///     present in its window's workspace list (the app-side
    ///     `manager.tabs.contains` check).
    ///   - sourceManagerWorkspaceCount: The number of workspaces in the source
    ///     window's manager (`manager.tabs.count` app-side).
    /// - Returns: ``Outcome/none`` when the workspace is non-empty or already
    ///   gone, ``Outcome/closeWorkspace`` when the empty workspace's window holds
    ///   other workspaces, otherwise ``Outcome/closeWindow``.
    public func outcome(
        sourceWorkspaceIsEmpty: Bool,
        sourceWorkspaceStillInManager: Bool,
        sourceManagerWorkspaceCount: Int
    ) -> Outcome {
        guard sourceWorkspaceIsEmpty else { return .none }
        guard sourceWorkspaceStillInManager else { return .none }
        return sourceManagerWorkspaceCount > 1 ? .closeWorkspace : .closeWindow
    }
}
