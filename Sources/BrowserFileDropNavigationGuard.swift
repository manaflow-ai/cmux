import AppKit
import Foundation
import WebKit

@MainActor
final class BrowserFileDropNavigationGuard {
    static let shared = BrowserFileDropNavigationGuard()

    private static let timeToLive: TimeInterval = 5
    private var records: [ObjectIdentifier: Record] = [:]

    private final class Record {
        weak var webView: WKWebView?
        let webViewID: ObjectIdentifier
        /// Every file URL delivered by the drop, in pasteboard order. WebKit's
        /// fallback navigation names only one file of a multi-file drop, but the
        /// preview fallback must open all of them.
        let urls: [URL]
        let paths: Set<String>
        let timestamp: Date

        init(webView: WKWebView, urls: [URL], timestamp: Date) {
            self.webView = webView
            self.webViewID = ObjectIdentifier(webView)
            self.urls = urls
            self.paths = Set(urls.map(\.path))
            self.timestamp = timestamp
        }
    }

    func recordDelivery(
        webView: WKWebView,
        pasteboard: NSPasteboard,
        now: Date = Date()
    ) {
        pruneExpiredRecords(now: now)
        guard DragOverlayRoutingPolicy.hasFileURL(pasteboard.types) else { return }
        // Already standardized and deduped by path, in pasteboard order.
        let urls = DragOverlayRoutingPolicy.fileURLs(from: pasteboard)
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)
        guard !urls.isEmpty else { return }
        records[ObjectIdentifier(webView)] = Record(
            webView: webView,
            urls: urls,
            timestamp: now
        )
    }

    /// Consumes (once) the drop record that `url` belongs to and returns every
    /// file URL delivered by that drop, or nil when the navigation does not
    /// match a live record. Callers preview the full list, not just the single
    /// file WebKit chose to navigate to.
    func consumeDropNavigation(
        webView: WKWebView,
        url: URL,
        now: Date = Date()
    ) -> [URL]? {
        pruneExpiredRecords(now: now)
        let webViewID = ObjectIdentifier(webView)
        guard let record = records[webViewID],
              record.webViewID == webViewID,
              record.webView === webView,
              record.paths.contains(url.standardizedFileURL.path) else {
            return nil
        }
        records[webViewID] = nil
        return record.urls
    }

    static func isDropFallbackNavigation(
        url: URL?,
        isMainFrame: Bool,
        navigationType: WKNavigationType
    ) -> Bool {
        guard let url else { return false }
        return url.isFileURL && isMainFrame && navigationType == .other
    }

    private func pruneExpiredRecords(now: Date) {
        records = records.filter { _, record in
            guard record.webView != nil else { return false }
            return now.timeIntervalSince(record.timestamp) <= Self.timeToLive
        }
    }
}
