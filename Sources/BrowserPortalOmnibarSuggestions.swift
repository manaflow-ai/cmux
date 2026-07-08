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
        // AppKit passes hit-test points in the superview's coordinate space.
        // Compare the popup frame in this hosting view's own top-left local
        // space so offset overlays and flipped hosting views route consistently.
        guard let superview else { return nil }
        let localPoint = convert(point, from: superview)
        let topLeftPoint = isFlipped
            ? localPoint
            : NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
        guard popupFrameInTopLeftCoordinates.contains(topLeftPoint) else { return nil }
        return super.hitTest(point)
    }
}
