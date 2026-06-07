import Foundation

/// Pure policy deciding which edges a terminal should expand past the safe area,
/// given its layout context and the current vertical size class.
public struct MobileTerminalSafeAreaExpansionPolicy {
    private init() {}

    /// Computes the edges the terminal should expand into.
    /// - Parameters:
    ///   - context: The terminal's layout context.
    ///   - hasCompactVerticalSize: Whether the vertical size class is compact (landscape phone).
    ///   - includesBottom: Whether bottom expansion is allowed. Defaults to `true`.
    /// - Returns: The set of edges to expand, honoring the context's constraints.
    public static func edges(
        context: MobileTerminalSafeAreaContext,
        hasCompactVerticalSize: Bool,
        includesBottom: Bool = true
    ) -> MobileTerminalSafeAreaExpansionEdges {
        switch context {
        case .fullWidth:
            return MobileTerminalSafeAreaExpansionEdges(
                horizontal: hasCompactVerticalSize,
                bottom: includesBottom
            )
        case .splitSidebarVisible:
            return MobileTerminalSafeAreaExpansionEdges(
                horizontal: false,
                bottom: includesBottom
            )
        }
    }
}
