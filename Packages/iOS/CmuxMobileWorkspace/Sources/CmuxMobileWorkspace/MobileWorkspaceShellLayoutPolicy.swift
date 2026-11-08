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

    /// Whether the split layout's sidebar, rather than the system tab bar,
    /// hosts the top-level destinations.
    ///
    /// iPadOS draws the tab bar at the top of the screen, clear of the
    /// workspace detail. A regular-width iPhone (the unfolded iPhone Duo inner
    /// screen reports regular × regular) draws it at the bottom across both
    /// columns, over the detail's bottom controls, so the sidebar takes over.
    /// - Parameters:
    ///   - usesCompactStack: Whether the shell uses the compact stack layout.
    ///   - isPhoneIdiom: Whether the device uses the phone interface idiom.
    /// - Returns: `true` for the split layout on a phone.
    public static func hostsSplitDestinationsInSidebar(
        usesCompactStack: Bool,
        isPhoneIdiom: Bool
    ) -> Bool {
        !usesCompactStack && isPhoneIdiom
    }
}
