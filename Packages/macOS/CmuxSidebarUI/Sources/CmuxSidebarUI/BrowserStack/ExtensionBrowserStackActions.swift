public import Foundation
public import CmuxSidebarProviderKit

/// The host-side action bundle the extension browser-stack column needs to
/// drive workspace selection, drag-reorder mutations, accessibility moves, and
/// new-tab creation.
///
/// The browser-stack views (``ExtensionBrowserStackColumnView`` and its row,
/// tile, and group children) live in this package and hold only value
/// snapshots, so every reach back into app-target state (`TabManager`,
/// `CmuxExtensionSidebarSelection` provider resolution, workspace spawning)
/// is inverted to a closure here. The app constructs one value at composition
/// time; the views never import the workspace god object. This realizes the
/// `SidebarExtensionActionHandling` seam as a closure bundle rather than a
/// protocol, matching the closure-bundle shape the sibling drop delegates
/// already use (`onMove`, `onNewTab`).
public struct ExtensionBrowserStackActions {
    /// Focuses the workspace identified by `workspaceId` (drives
    /// `selectExtensionSidebarWorkspace` in the host).
    public let selectWorkspace: (UUID) -> Void

    /// Commits a planned drag-reorder mutation, returning whether the provider
    /// accepted it (drives `handleExtensionSidebarMutation` in the host).
    public let commitMutation: (CmuxSidebarProviderMutation) -> Bool

    /// Shifts the workspace by `delta` rows via the accessibility Move Up/Down
    /// actions and the reorder context menu (drives
    /// `moveExtensionBrowserStackWorkspace` in the host).
    public let moveWorkspace: (UUID, Int) -> Void

    /// Opens a new tab (drives `onNewTab` in the host).
    public let newTab: () -> Void

    /// Resolves a provider text value (plain, localized, or relative-date) to a
    /// display string, using the host bundle for localization. Kept app-side so
    /// `String(localized:)` binds to the main bundle, not this package's bundle.
    public let renderText: (CmuxSidebarProviderText?, Date) -> String?

    /// Creates the browser-stack action bundle.
    /// - Parameters:
    ///   - selectWorkspace: Focuses a workspace by id.
    ///   - commitMutation: Commits a drag-reorder mutation, returning success.
    ///   - moveWorkspace: Shifts a workspace by a row delta.
    ///   - newTab: Opens a new tab.
    ///   - renderText: Resolves provider text to a display string app-side.
    public init(
        selectWorkspace: @escaping (UUID) -> Void,
        commitMutation: @escaping (CmuxSidebarProviderMutation) -> Bool,
        moveWorkspace: @escaping (UUID, Int) -> Void,
        newTab: @escaping () -> Void,
        renderText: @escaping (CmuxSidebarProviderText?, Date) -> String?
    ) {
        self.selectWorkspace = selectWorkspace
        self.commitMutation = commitMutation
        self.moveWorkspace = moveWorkspace
        self.newTab = newTab
        self.renderText = renderText
    }
}
