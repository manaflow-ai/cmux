public import SwiftUI

/// Pure layout policy deciding whether the workspace shell uses the compact
/// (stacked) navigation style based on the current size classes.
public struct MobileWorkspaceShellLayoutPolicy {
    private init() {}

    /// Whether the shell should use a compact, stacked navigation layout.
    /// - Parameters:
    ///   - horizontalSizeClass: The current horizontal size class.
    ///   - verticalSizeClass: The current vertical size class.
    /// - Returns: `true` when either dimension is compact.
    public static func usesCompactStack(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        horizontalSizeClass == .compact || verticalSizeClass == .compact
    }
}
