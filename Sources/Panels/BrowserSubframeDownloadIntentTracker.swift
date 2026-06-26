import Foundation
import WebKit

final class BrowserSubframeDownloadIntentTracker {
    private static let intentLifetime: TimeInterval = 10
    private static let maxIntentCount = 64

    private var recentIntentKeys: [(key: String, recordedAt: TimeInterval)] = []

    func updateIfNeeded(_ navigationAction: WKNavigationAction) {
        guard navigationAction.targetFrame?.isMainFrame == false,
              let url = navigationAction.request.url,
              Self.isHTTPDownloadIntentURL(url),
              (navigationAction.request.httpMethod?.uppercased() ?? "GET") == "GET" else { return }
        guard navigationAction.navigationType != .linkActivated else { return }
        guard let sourceURL = navigationAction.targetFrame?.request.url else { return }
        recordRedirectIfNeeded(from: sourceURL, to: url)
    }

    func record(_ url: URL) {
        guard Self.isHTTPDownloadIntentURL(url) else { return }
        let now = ProcessInfo.processInfo.systemUptime; prune(now: now)
        let key = Self.downloadIntentKey(for: url); recentIntentKeys.removeAll { $0.key == key }
        recentIntentKeys.append((key, now))
        if recentIntentKeys.count > Self.maxIntentCount {
            recentIntentKeys.removeFirst(recentIntentKeys.count - Self.maxIntentCount)
        }
    }

    func recordRedirectIfNeeded(from sourceURL: URL, to url: URL) {
        guard Self.isHTTPDownloadIntentURL(sourceURL),
              Self.isHTTPDownloadIntentURL(url) else { return }
        let now = ProcessInfo.processInfo.systemUptime; prune(now: now)
        let sourceKey = Self.downloadIntentKey(for: sourceURL)
        guard sourceKey != Self.downloadIntentKey(for: url),
              let sourceIndex = recentIntentKeys.firstIndex(where: { $0.key == sourceKey }) else { return }
        recentIntentKeys.remove(at: sourceIndex)
        record(url)
    }

    func consume(for responseURL: URL?) -> Bool {
        guard let responseURL, Self.isHTTPDownloadIntentURL(responseURL) else { return false }
        let now = ProcessInfo.processInfo.systemUptime; prune(now: now)
        let key = Self.downloadIntentKey(for: responseURL)
        if let index = recentIntentKeys.firstIndex(where: { $0.key == key }) {
            recentIntentKeys.remove(at: index)
            return true
        }
        return false
    }

    private func prune(now: TimeInterval) {
        recentIntentKeys.removeAll { now - $0.recordedAt > Self.intentLifetime }
    }

    private static func isHTTPDownloadIntentURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private static func downloadIntentKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}
