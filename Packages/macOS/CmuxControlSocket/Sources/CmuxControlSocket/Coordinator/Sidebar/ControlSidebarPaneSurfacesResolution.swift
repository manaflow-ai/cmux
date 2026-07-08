internal import Foundation

/// The outcome of resolving the v1 `list_pane_surfaces` target pane and its
/// bonsplit tabs.
public enum ControlSidebarPaneSurfacesResolution: Sendable, Equatable {
    /// One bonsplit tab row of the listing.
    public struct Row: Sendable, Equatable {
        /// Whether this tab is the pane's selected tab.
        public let isSelected: Bool
        /// The bonsplit tab title.
        public let title: String
        /// The owning panel's UUID string, or `nil` when unknown.
        public let panelIDString: String?

        /// Creates a row.
        ///
        /// - Parameters:
        ///   - isSelected: Whether this tab is the pane's selected tab.
        ///   - title: The bonsplit tab title.
        ///   - panelIDString: The owning panel's UUID string, if known.
        public init(isSelected: Bool, title: String, panelIDString: String?) {
            self.isSelected = isSelected
            self.title = title
            self.panelIDString = panelIDString
        }
    }

    /// No workspace is selected.
    case noTabSelected
    /// The `--pane` argument did not resolve to a pane.
    case paneNotFound
    /// No explicit pane and no focused pane to list from.
    case noPaneTarget
    /// The resolved pane's tabs, in order.
    case rows([Row])
}
