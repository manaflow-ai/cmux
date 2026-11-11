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

    /// The `UserDefaults` key holding whether the phone split sidebar was
    /// last hidden.
    public static let splitSidebarHiddenStorageKey = "cmux.workspaces.splitSidebarHidden"

    /// The column visibility a phone split layout opens with, so a relaunch or
    /// a resume after the system ended the app puts the sidebar back the way
    /// the user left it.
    /// - Parameter sidebarWasHidden: The remembered sidebar state.
    /// - Returns: `.detailOnly` when the sidebar was hidden, else `.all`.
    public static func restoredSplitColumnVisibility(
        sidebarWasHidden: Bool
    ) -> NavigationSplitViewVisibility {
        sidebarWasHidden ? .detailOnly : .all
    }

    /// The column visibility a phone split layout opens with on launch.
    ///
    /// With no workspace picked yet the sidebar's list is the only useful
    /// content, so it stays shown; the remembered state takes over once the
    /// user picks a workspace.
    /// - Parameters:
    ///   - sidebarWasHidden: The remembered sidebar state.
    ///   - hasSelectedWorkspace: Whether a workspace is already picked.
    /// - Returns: `.all` until a workspace is picked, then the restored state.
    public static func launchSplitColumnVisibility(
        sidebarWasHidden: Bool,
        hasSelectedWorkspace: Bool
    ) -> NavigationSplitViewVisibility {
        guard hasSelectedWorkspace else { return .all }
        return restoredSplitColumnVisibility(sidebarWasHidden: sidebarWasHidden)
    }

    /// Whether the phone split detail shows the first workspace when none is
    /// picked. The phone opens on the list instead, like the compact layout.
    /// - Parameter hostsSplitDestinationsInSidebar: Whether this is the phone split layout.
    /// - Returns: `false` for the phone split layout.
    public static func splitDetailFallsBackToFirstWorkspace(
        hostsSplitDestinationsInSidebar: Bool
    ) -> Bool {
        !hostsSplitDestinationsInSidebar
    }

    /// Whether a launch keeps the phone split detail empty until the user
    /// picks a workspace. The store selects one on its own (the first cached
    /// row, then the Mac's focused workspace once the list arrives); a phone
    /// opens on the workspace list instead, in every orientation. A pending
    /// deep link (a notification tap) keeps its target.
    /// - Parameters:
    ///   - isPhoneIdiom: Whether the device is a phone.
    ///   - hasPendingDeeplink: Whether a deep link is waiting to open a workspace.
    /// - Returns: `true` when the phone should start on the list.
    public static func launchAwaitsWorkspacePick(
        isPhoneIdiom: Bool,
        hasPendingDeeplink: Bool
    ) -> Bool {
        isPhoneIdiom && !hasPendingDeeplink
    }

    /// Whether a column visibility hides the phone split sidebar.
    ///
    /// The split opens on an explicit visibility (see
    /// ``restoredSplitColumnVisibility(sidebarWasHidden:)``), so every later
    /// change is a shown or hidden choice. `.automatic` is not ruled out here
    /// because this type's equality reports it equal to `.detailOnly`.
    /// - Parameter visibility: The split view's column visibility.
    /// - Returns: `false` when the sidebar column is shown.
    public static func splitSidebarIsHidden(
        _ visibility: NavigationSplitViewVisibility
    ) -> Bool {
        !(visibility == .all || visibility == .doubleColumn)
    }
}
