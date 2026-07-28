import Foundation
import WebKit

/// Selects the browser identity that best matches an embedded WebKit view for
/// each top-level destination.
struct BrowserUserAgentPolicy: Sendable {
    static let system = BrowserUserAgentPolicy()

    let safariCompatibleUserAgent: String

    init(safariVersion: String) {
        let resolvedVersion = Self.normalizedVersion(safariVersion)
            ?? Self.fallbackSafariVersion(for: ProcessInfo.processInfo.operatingSystemVersion)
        safariCompatibleUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/\(resolvedVersion) Safari/605.1.15"
    }

    init() {
        self.init(
            safariVersion: Self.installedSafariVersion()
                ?? Self.fallbackSafariVersion(for: ProcessInfo.processInfo.operatingSystemVersion)
        )
    }

    /// Returns `nil` when WebKit should construct its native embedded identity.
    func customUserAgent(for url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return Self.isGoogleSheetsURL(url) ? nil : safariCompatibleUserAgent
    }

    @MainActor
    func apply(to webView: WKWebView, for url: URL?) {
        let resolvedUserAgent = customUserAgent(for: url)
        guard webView.customUserAgent != resolvedUserAgent else { return }
        webView.customUserAgent = resolvedUserAgent
    }

    private static func isGoogleSheetsURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "sheets.google.com" || host == "spreadsheets.google.com" {
            return true
        }
        guard host == "docs.google.com" else { return false }
        return url.path.split(separator: "/", omittingEmptySubsequences: true).first?
            .lowercased() == "spreadsheets"
    }

    private static func installedSafariVersion() -> String? {
        let safariBundleURL = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        guard let version = Bundle(url: safariBundleURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return normalizedVersion(version)
    }

    private static func normalizedVersion(_ version: String) -> String? {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && Int($0) != nil }) else {
            return nil
        }
        return components.joined(separator: ".")
    }

    private static func fallbackSafariVersion(for osVersion: OperatingSystemVersion) -> String {
        if osVersion.majorVersion >= 26 {
            return "\(osVersion.majorVersion).\(osVersion.minorVersion)"
        }
        if osVersion.majorVersion >= 11 {
            return "\(osVersion.majorVersion + 3).0"
        }
        return "13.1"
    }
}

extension WKWebView {
    @MainActor
    func applyBrowserUserAgentPolicy(for url: URL?) {
        BrowserUserAgentPolicy.system.apply(to: self, for: url)
    }
}
