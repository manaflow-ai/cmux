/// Pure layout policy deciding whether the workspace shell uses the compact
/// (stacked) navigation style based on the current size classes.
public struct MobileWorkspaceShellLayoutPolicy {
    private init() {}

    /// Whether the shell should use a compact, stacked navigation layout.
    /// - Parameters:
    ///   - hasCompactHorizontalSize: Whether horizontal space is compact.
    ///   - hasCompactVerticalSize: Whether vertical space is compact.
    /// - Returns: `true` when either dimension is compact.
    public static func usesCompactStack(
        hasCompactHorizontalSize: Bool,
        hasCompactVerticalSize: Bool
    ) -> Bool {
        hasCompactHorizontalSize || hasCompactVerticalSize
    }
}
