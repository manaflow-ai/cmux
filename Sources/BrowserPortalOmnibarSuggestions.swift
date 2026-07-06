import AppKit
import SwiftUI

struct BrowserPortalOmnibarSuggestionsConfiguration {
    let panelId: UUID
    let popupFrame: CGRect
    let colorScheme: ColorScheme
    let engineName: String
    let items: [OmnibarSuggestion]
    let selectedIndex: Int
    let isLoadingRemoteSuggestions: Bool
    let searchSuggestionsEnabled: Bool
    let onCommit: (OmnibarSuggestion) -> Void
    let onHighlight: (Int) -> Void
}

struct BrowserPortalOmnibarSuggestionsOverlay: View {
    let configuration: BrowserPortalOmnibarSuggestionsConfiguration

    var body: some View {
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

final class BrowserPortalOmnibarSuggestionsHostingView: NSHostingView<BrowserPortalOmnibarSuggestionsOverlay> {
    var popupFrameInTopLeftCoordinates: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        let topLeftPoint: NSPoint
        if isFlipped {
            topLeftPoint = point
        } else {
            topLeftPoint = NSPoint(x: point.x, y: bounds.height - point.y)
        }
        guard popupFrameInTopLeftCoordinates.contains(topLeftPoint) else { return nil }
        return super.hitTest(point)
    }
}
