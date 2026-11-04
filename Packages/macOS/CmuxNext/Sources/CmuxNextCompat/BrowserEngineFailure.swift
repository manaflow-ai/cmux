public import Foundation

/// A browser failure the person saw but no crash report recorded: a page's
/// renderer process ended (the sad tab, "Aw, Snap!") or a main-frame load
/// failed (Chromium's net error page or interstitial).
///
/// Holds no page content: the page address is reduced to its scheme and
/// host (``site``), never a path, query or fragment. Crash reporting sends
/// it (`BrowserFailureReporter` in `CmuxNextCrashReporting`). The browser
/// makes it (`BrowserEngineFailure.rendererTerminated` in
/// `CmuxNextBrowserCore`, ``loadFailed(code:name:url:interstitial:versions:)``);
/// it lives here, below both, so neither depends on the other.
///
/// ```swift
/// let failure = BrowserEngineFailure.loadFailed(code: -105, name: "net::ERR_NAME_NOT_RESOLVED",
///                                               url: URL(string: "https://example.com/a?b"), interstitial: false)
/// failure.codeName  // "ERR_NAME_NOT_RESOLVED"
/// failure.site      // "https://example.com"
/// ```
public nonisolated struct BrowserEngineFailure: Hashable, Sendable {
    /// What failed.
    public enum Kind: String, Hashable, Sendable {
        /// The page's renderer process ended while the page was open.
        case rendererTerminated = "renderer_terminated"
        /// The main frame's load failed (a net error or an interstitial).
        case loadFailed = "load_failed"
    }

    /// Chromium's net error ERR_ABORTED: a cancelled load (Stop, a replacing
    /// navigation, a download), not a failure.
    public static let abortedNetError = -3
    /// The longest ``reason`` kept.
    public static let maxReasonLength = 120

    public var kind: Kind
    /// The raw code: the renderer's `waitpid` status, or the net error
    /// (negative, `-105`).
    public var code: Int
    /// The code as a name: `SIGTRAP` or `exit 3` for a renderer,
    /// `ERR_NAME_NOT_RESOLVED` for a load; nil when the engine gave none.
    public var codeName: String?
    /// Why the renderer ended (`BrowserProcessExit.Reason`'s raw value:
    /// `crashed`, `killed`, `outOfMemory`, `launchFailed`, `integrityFailure`,
    /// `abnormal`); nil for a load failure.
    public var termination: String?
    /// The page's scheme and host, `https://example.com` (``site(of:)``); nil when unknown.
    public var site: String?
    /// For a load failure: Chromium shows its own interstitial (a certificate warning).
    public var interstitial: Bool
    /// The helper process kind that ended (`renderer`); nil for a load failure.
    public var processKind: String?
    /// The engine's own short text for a renderer end, at most ``maxReasonLength`` characters.
    public var reason: String?
    /// The engine versions that ran the page.
    public var versions: BrowserEngineVersions

    /// - Parameters:
    ///   - kind: What failed.
    ///   - code: The raw code (``code``).
    ///   - codeName: The code as a name (``codeName``).
    ///   - termination: Why the renderer ended; nil for a load failure.
    ///   - site: The page's scheme and host only.
    ///   - interstitial: Chromium shows its own interstitial.
    ///   - processKind: The helper process kind that ended.
    ///   - reason: The engine's short text; cut to ``maxReasonLength``.
    ///   - versions: The engine versions.
    public init(kind: Kind, code: Int, codeName: String? = nil, termination: String? = nil,
                site: String? = nil, interstitial: Bool = false, processKind: String? = nil, reason: String? = nil,
                versions: BrowserEngineVersions = BrowserEngineVersions()) {
        self.kind = kind
        self.code = code
        self.codeName = codeName
        self.termination = termination
        self.site = site
        self.interstitial = interstitial
        self.processKind = processKind
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reason = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maxReasonLength))
        self.versions = versions
    }

    /// CEF's `OnLoadError` for a page's main frame.
    /// - Parameters:
    ///   - code: The net error (`-105`).
    ///   - name: Chromium's error text, `net::ERR_NAME_NOT_RESOLVED`; the `net::` prefix is dropped.
    ///   - url: The failed address; only its scheme and host are kept.
    ///   - interstitial: Chromium shows its own interstitial for it.
    ///   - versions: The engine versions.
    /// - Returns: The failure.
    public static func loadFailed(code: Int, name: String, url: URL?, interstitial: Bool,
                                  versions: BrowserEngineVersions = BrowserEngineVersions()) -> BrowserEngineFailure {
        let bare = name.hasPrefix("net::") ? String(name.dropFirst("net::".count)) : name
        return BrowserEngineFailure(kind: .loadFailed, code: code, codeName: bare.isEmpty ? nil : bare,
                                    site: site(of: url), interstitial: interstitial, versions: versions)
    }

    /// Whether this is a failure to report: a cancelled load (ERR_ABORTED,
    /// which Stop and every replacing navigation cause) and a load error
    /// with no error code are not.
    public var isReportable: Bool {
        switch kind {
        case .rendererTerminated: true
        case .loadFailed: code != 0 && code != Self.abortedNetError && codeName != "ERR_ABORTED"
        }
    }

    /// The host part of ``site``, `example.com`; nil when there is none.
    public var host: String? {
        guard let site, let range = site.range(of: "://") else { return nil }
        let host = site[range.upperBound...]
        return host.isEmpty ? nil : String(host)
    }

    /// The same failure on the same site: what a crash loop repeats. Kind,
    /// termination, code and host.
    public var dedupeKey: String {
        [kind.rawValue, termination ?? "-", String(code), host ?? "-"].joined(separator: "|")
    }

    /// `url` as its scheme and host only: `https://example.com` for
    /// `https://user@example.com:8443/a?b#c`, `about:` for `about:blank`,
    /// `file:` for a file. Nil when `url` has no scheme.
    /// - Parameter url: The page's address.
    /// - Returns: The scheme and host, lowercased.
    public static func site(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return "\(scheme):" }
        return "\(scheme)://\(host)"
    }
}
