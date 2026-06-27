import Foundation
import WebKit

final class BrowserSubframeDownloadIntentTracker {
    private static let intentLifetime: TimeInterval = 10
    private static let maxIntentCount = 64

    private var recentIntentKeys: [(key: String, recordedAt: TimeInterval)] = []
    private var recentUserActivatedSubframeNavigationKeys: [(key: String, recordedAt: TimeInterval)] = []
    private var recentPDFPrintIntentKeys: [(key: String, recordedAt: TimeInterval)] = []
    private var renderedSubframePDFKeys: [String] = []

    func updateIfNeeded(_ navigationAction: WKNavigationAction, hasUserActivation: Bool = false) {
        guard navigationAction.targetFrame?.isMainFrame == false,
              let url = navigationAction.request.url,
              Self.isHTTPDownloadIntentURL(url),
              (navigationAction.request.httpMethod?.uppercased() ?? "GET") == "GET" else { return }
        if hasUserActivation {
            recordUserActivatedSubframeNavigation(url)
        }
        if navigationAction.navigationType == .linkActivated {
            record(url)
            return
        }
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

    func recordUserActivatedSubframeNavigation(_ url: URL) {
        guard Self.isHTTPDownloadIntentURL(url) else { return }
        let now = ProcessInfo.processInfo.systemUptime; prune(now: now)
        let key = Self.subframePDFIntentKey(for: url)
        recentUserActivatedSubframeNavigationKeys.removeAll { $0.key == key }
        recentUserActivatedSubframeNavigationKeys.append((key, now))
        if recentUserActivatedSubframeNavigationKeys.count > Self.maxIntentCount {
            recentUserActivatedSubframeNavigationKeys.removeFirst(recentUserActivatedSubframeNavigationKeys.count - Self.maxIntentCount)
        }
    }

    func consumeUserActivatedPreviouslyRenderedSubframePDF(responseURL: URL?, mimeType: String?, isForMainFrame: Bool) -> Bool {
        guard !isForMainFrame,
              Self.isPDFMIMEType(mimeType),
              let responseURL,
              Self.isHTTPDownloadIntentURL(responseURL) else { return false }
        let now = ProcessInfo.processInfo.systemUptime; prune(now: now)
        let key = Self.subframePDFIntentKey(for: responseURL)
        guard renderedSubframePDFKeys.contains(key),
              let index = recentUserActivatedSubframeNavigationKeys.firstIndex(where: { $0.key == key }) else { return false }
        recentUserActivatedSubframeNavigationKeys.remove(at: index)
        return true
    }

    func markRenderedSubframePDFIfNeeded(responseURL: URL?, mimeType: String?, isForMainFrame: Bool) {
        guard !isForMainFrame,
              Self.isPDFMIMEType(mimeType),
              let responseURL,
              Self.isHTTPDownloadIntentURL(responseURL) else { return }
        let key = Self.subframePDFIntentKey(for: responseURL)
        recentUserActivatedSubframeNavigationKeys.removeAll { $0.key == key }
        renderedSubframePDFKeys.removeAll { $0 == key }
        renderedSubframePDFKeys.append(key)
        if renderedSubframePDFKeys.count > Self.maxIntentCount {
            renderedSubframePDFKeys.removeFirst(renderedSubframePDFKeys.count - Self.maxIntentCount)
        }
    }

    func recordPDFPrintIntent(_ url: URL) {
        guard Self.isHTTPDownloadIntentURL(url),
              Self.isPDFPrintRequestURL(url) else { return }
        let now = ProcessInfo.processInfo.systemUptime; prune(now: now)
        let key = Self.pdfPrintIntentKey(for: url)
        recentPDFPrintIntentKeys.removeAll { $0.key == key }
        recentPDFPrintIntentKeys.append((key, now))
        if recentPDFPrintIntentKeys.count > Self.maxIntentCount {
            recentPDFPrintIntentKeys.removeFirst(recentPDFPrintIntentKeys.count - Self.maxIntentCount)
        }
    }

    func consumePDFPrintIntent(responseURL: URL?, mimeType: String?, isForMainFrame: Bool) -> Bool {
        guard isForMainFrame,
              Self.isPDFMIMEType(mimeType),
              let responseURL,
              Self.isHTTPDownloadIntentURL(responseURL),
              Self.isPDFPrintRequestURL(responseURL) else { return false }
        let now = ProcessInfo.processInfo.systemUptime; prune(now: now)
        let key = Self.pdfPrintIntentKey(for: responseURL)
        guard let index = recentPDFPrintIntentKeys.firstIndex(where: { $0.key == key }) else { return false }
        recentPDFPrintIntentKeys.remove(at: index)
        return true
    }

    private func prune(now: TimeInterval) {
        recentIntentKeys.removeAll { now - $0.recordedAt > Self.intentLifetime }
        recentUserActivatedSubframeNavigationKeys.removeAll { now - $0.recordedAt > Self.intentLifetime }
        recentPDFPrintIntentKeys.removeAll { now - $0.recordedAt > Self.intentLifetime }
    }

    private static func isHTTPDownloadIntentURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    private static func isPDFMIMEType(_ mimeType: String?) -> Bool {
        mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("application/pdf") == .orderedSame
    }

    private static func isPDFPrintRequestURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.queryItems?.contains {
            $0.name.caseInsensitiveCompare("print") == .orderedSame &&
                (($0.value ?? "").caseInsensitiveCompare("true") == .orderedSame || $0.value == "1")
        } == true
    }

    private static func downloadIntentKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func subframePDFIntentKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func pdfPrintIntentKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}
