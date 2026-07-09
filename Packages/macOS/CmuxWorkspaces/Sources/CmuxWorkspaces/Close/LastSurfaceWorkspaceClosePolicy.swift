/// Pure rule deciding whether closing a tab's *last* surface should close the
/// whole workspace, shared by the window's Bonsplit close witness
/// (`shouldCloseWorkspaceOnLastSurface(for:)`).
///
/// The witness used to inline a four-clause `guard` that mixed three live reads
/// with the boolean rule that ties them together: the workspace had at most one
/// panel, the closing tab actually maps to a panel, and the resolved tab
/// manager still owns this workspace. This value type owns only that final
/// conjunction, over three already-resolved booleans, so the live lookups
/// (`panels.count`, `panelIdFromSurfaceId(tabId) != nil`, and the
/// `manager.tabs.contains` ownership check) stay app-side where the workspace
/// state lives.
///
/// It carries no dependencies and is constructed at the call site
/// (`LastSurfaceWorkspaceClosePolicy()`), mirroring the legacy inline guard:
/// the rule is a pure function of its inputs with no state to inject.
public struct LastSurfaceWorkspaceClosePolicy: Sendable {
    /// Creates the policy.
    public init() {}

    /// Whether the workspace should close because its last surface is closing.
    ///
    /// Reproduces the legacy guard exactly: the workspace must hold at most one
    /// panel (`panelCount <= 1`), the closing tab must map to a panel
    /// (`closingTabHasPanel`), and the resolved tab manager must still own this
    /// workspace (`managerOwnsWorkspace`, already folding in the manager being
    /// non-nil). All three must hold; otherwise the workspace stays open.
    ///
    /// - Parameters:
    ///   - panelCount: the workspace's current panel count (`panels.count`).
    ///   - closingTabHasPanel: whether the closing tab id maps to a panel
    ///     (`panelIdFromSurfaceId(tabId) != nil`).
    ///   - managerOwnsWorkspace: whether the resolved tab manager exists and its
    ///     tabs contain this workspace
    ///     (`manager != nil && manager.tabs.contains { $0.id == id }`).
    public func shouldCloseWorkspace(
        panelCount: Int,
        closingTabHasPanel: Bool,
        managerOwnsWorkspace: Bool
    ) -> Bool {
        panelCount <= 1 && closingTabHasPanel && managerOwnsWorkspace
    }
}
