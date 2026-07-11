import Foundation
import WebKit

@available(macOS 15.4, *)
@MainActor
struct BrowserWebExtensionTabMetadataSnapshot: Equatable {
    let title: String?
    let url: URL?
    let isLoading: Bool
    let isMuted: Bool

    init(panel: BrowserPanel) {
        title = panel.webView.title
        url = panel.webView.url
        isLoading = panel.webView.isLoading
        isMuted = panel.isMuted
    }

    func changedProperties(
        comparedTo previous: BrowserWebExtensionTabMetadataSnapshot
    ) -> WKWebExtension.TabChangedProperties {
        var properties: WKWebExtension.TabChangedProperties = []
        if title != previous.title { properties.insert(.title) }
        if url != previous.url { properties.insert(.URL) }
        if isLoading != previous.isLoading { properties.insert(.loading) }
        if isMuted != previous.isMuted { properties.insert(.muted) }
        return properties
    }
}
