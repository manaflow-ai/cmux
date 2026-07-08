import SwiftUI

struct BrowserPortalOmnibarSuggestionsOverlay: View {
    let configuration: BrowserPortalOmnibarSuggestionsConfiguration

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                OmnibarSuggestionsView(
                    engineName: configuration.engineName,
                    items: configuration.items,
                    badges: configuration.items.map { $0.trailingBadgeText },
                    selectedIndex: configuration.selectedIndex,
                    isLoadingRemoteSuggestions: configuration.isLoadingRemoteSuggestions,
                    searchSuggestionsEnabled: configuration.searchSuggestionsEnabled,
                    accessibilityLabel: String(localized: "browser.addressBarSuggestions", defaultValue: "Address bar suggestions"),
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
