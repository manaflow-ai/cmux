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
        let paths: Set<String>
        let timestamp: Date

        init(webView: WKWebView, paths: Set<String>, timestamp: Date) {
            self.webView = webView
            self.webViewID = ObjectIdentifier(webView)
            self.paths = paths
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
        let paths = Set(
            DragOverlayRoutingPolicy.fileURLs(from: pasteboard)
                .filter(\.isFileURL)
                .map { $0.standardizedFileURL.path }
        )
        guard !paths.isEmpty else { return }
        records[ObjectIdentifier(webView)] = Record(
            webView: webView,
            paths: paths,
            timestamp: now
        )
    }

    func consumeDropNavigation(
        webView: WKWebView,
        url: URL,
        now: Date = Date()
    ) -> Bool {
        pruneExpiredRecords(now: now)
        let webViewID = ObjectIdentifier(webView)
        guard let record = records[webViewID],
              record.webViewID == webViewID,
              record.webView === webView,
              record.paths.contains(url.standardizedFileURL.path) else {
            return false
        }
        records[webViewID] = nil
        return true
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
