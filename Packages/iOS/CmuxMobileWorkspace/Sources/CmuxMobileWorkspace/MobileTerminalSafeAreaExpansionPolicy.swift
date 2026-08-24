import Foundation

/// Pure policy deciding which edges a terminal should expand past the safe area,
/// given its layout context, the current vertical size class, and the edge the
/// camera cutout occupies.
public struct MobileTerminalSafeAreaExpansionPolicy {
    private init() {}

    /// Computes the edges the terminal should expand into.
    ///
    /// In compact landscape (landscape phone) the terminal claims the
    /// horizontal safe areas so the live area fills edge-to-edge, except the
    /// edge holding the camera cutout (Dynamic Island / notch): that edge keeps
    /// its system safe-area inset so terminal content never renders under the
    /// hardware. Devices without a cutout report zero horizontal insets, so
    /// protecting an edge there costs nothing.
    /// - Parameters:
    ///   - context: The terminal's layout context.
    ///   - hasCompactVerticalSize: Whether the vertical size class is compact (landscape phone).
    ///   - cameraEdge: The horizontal edge the camera cutout occupies, or `.none` when there is none to protect.
    ///   - includesBottom: Whether bottom expansion is allowed. Defaults to `true`.
    /// - Returns: The set of edges to expand, honoring the context's constraints.
    public static func edges(
        context: MobileTerminalSafeAreaContext,
        hasCompactVerticalSize: Bool,
        cameraEdge: MobileTerminalLandscapeCameraEdge,
        includesBottom: Bool = true
    ) -> MobileTerminalSafeAreaExpansionEdges {
        switch context {
        case .fullWidth:
            return MobileTerminalSafeAreaExpansionEdges(
                leading: hasCompactVerticalSize && cameraEdge != .leading,
                trailing: hasCompactVerticalSize && cameraEdge != .trailing,
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
