public import SwiftUI

/// SwiftUI overlay that positions the omnibar suggestions popup inside the
/// in-window browser portal.
///
/// Renders `OmnibarSuggestionsView` pinned to the portal's top-leading corner,
/// sized and offset from the configuration's `popupFrame` (top-left coordinate
/// space) so the popup lines up with the panel's omnibar field. Holds the popup
/// callbacks via its `configuration`, so it is main-actor-only and not
/// `Sendable`.
public struct BrowserPortalOmnibarSuggestionsOverlay: View {
    /// Suggestion rows, placement, and callbacks the popup renders from.
    public let configuration: BrowserPortalOmnibarSuggestionsConfiguration

    /// Creates the overlay for one panel's omnibar suggestions.
    /// - Parameter configuration: Suggestion rows, placement, and callbacks.
    public init(configuration: BrowserPortalOmnibarSuggestionsConfiguration) {
        self.configuration = configuration
    }

    public var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                OmnibarSuggestionsView(
                    engineName: configuration.engineName,
                    items: configuration.items,
                    selectedIndex: configuration.selectedIndex,
                    isLoadingRemoteSuggestions: configuration.isLoadingRemoteSuggestions,
                    searchSuggestionsEnabled: configuration.searchSuggestionsEnabled,
                    onCommit: configuration.onCommit,
                    onHighlight: configuration.onHighlight
                )
                .frame(width: configuration.popupFrame.width)
                .offset(x: configuration.popupFrame.minX, y: configuration.popupFrame.minY)
                .environment(\.colorScheme, configuration.colorScheme)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
