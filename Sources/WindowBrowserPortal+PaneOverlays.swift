import AppKit
import Bonsplit
import ObjectiveC
import SwiftUI
import WebKit


// MARK: - Pane overlay & chrome updates
extension WindowBrowserPortal {
    private static func searchOverlayConfigurationsEquivalent(
        _ lhs: BrowserPortalSearchOverlayConfiguration?,
        _ rhs: BrowserPortalSearchOverlayConfiguration?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.panelId == rhs.panelId &&
                lhs.searchState === rhs.searchState &&
                lhs.focusRequestGeneration == rhs.focusRequestGeneration
        default:
            return false
        }
    }

    private static func omnibarSuggestionsConfigurationsEquivalent(
        _ lhs: BrowserPortalOmnibarSuggestionsConfiguration?,
        _ rhs: BrowserPortalOmnibarSuggestionsConfiguration?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.panelId == rhs.panelId &&
                rectApproximatelyEqual(lhs.popupFrame, rhs.popupFrame, epsilon: 0.5) &&
                lhs.colorScheme == rhs.colorScheme &&
                lhs.engineName == rhs.engineName &&
                lhs.items == rhs.items &&
                lhs.selectedIndex == rhs.selectedIndex &&
                lhs.isLoadingRemoteSuggestions == rhs.isLoadingRemoteSuggestions &&
                lhs.searchSuggestionsEnabled == rhs.searchSuggestionsEnabled
        default:
            return false
        }
    }

    func updateDropZoneOverlay(forWebViewId webViewId: ObjectIdentifier, zone: DropZone?) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.dropZone != zone else { return }
        entry.dropZone = zone
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setDropZoneOverlay(zone: zone)
    }

    func updatePaneDropContext(forWebViewId webViewId: ObjectIdentifier, context: BrowserPaneDropContext?) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard entry.paneDropContext != context else { return }
        entry.paneDropContext = context
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setPaneDropContext(context)
    }

    func updateSearchOverlay(
        forWebViewId webViewId: ObjectIdentifier,
        configuration: BrowserPortalSearchOverlayConfiguration?
    ) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard !Self.searchOverlayConfigurationsEquivalent(entry.searchOverlay, configuration) else { return }
        entry.searchOverlay = configuration
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setSearchOverlay(configuration)
    }

    func updateOmnibarSuggestions(
        forWebViewId webViewId: ObjectIdentifier,
        configuration: BrowserPortalOmnibarSuggestionsConfiguration?
    ) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        guard !Self.omnibarSuggestionsConfigurationsEquivalent(entry.omnibarSuggestions, configuration) else { return }
        entry.omnibarSuggestions = configuration
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setOmnibarSuggestions(configuration)
    }

    func searchOverlayPanelId(for responder: NSResponder) -> UUID? {
        for entry in entriesByWebViewId.values {
            if let panelId = entry.containerView?.searchOverlayPanelId(for: responder) {
                return panelId
            }
        }
        return nil
    }

    @discardableResult
    func yieldSearchOverlayFocusIfOwned(by panelId: UUID) -> Bool {
        guard let window else { return false }
        for entry in entriesByWebViewId.values {
            if entry.containerView?.yieldSearchOverlayFocusIfOwned(by: panelId, in: window) == true {
                return true
            }
        }
        return false
    }

    func updatePaneTopChromeHeight(forWebViewId webViewId: ObjectIdentifier, height: CGFloat) {
        guard var entry = entriesByWebViewId[webViewId] else { return }
        let resolvedHeight = max(0, height)
        guard abs(entry.paneTopChromeHeight - resolvedHeight) > 0.5 else { return }
        entry.paneTopChromeHeight = resolvedHeight
        entriesByWebViewId[webViewId] = entry
        entry.containerView?.setPaneTopChromeHeight(resolvedHeight)
    }

}
