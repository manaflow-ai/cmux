public import Foundation
import CmuxNextBrowser
import CmuxNextDaemon

/// Which live browser tab of a pane a page-requested tab reuses instead of opening a duplicate
/// (#17444): the first, in strip order, that shows the same page (``samePage(_:_:)``) in the
/// same browser profile and engine. A foreground reuse loads the requested address when its
/// fragment differs, so a link to a section still opens at it. Explicit Duplicate Tab does not
/// come here (BrowserTabDuplicate).
public nonisolated struct BrowserTabMatch: Equatable, Sendable {
    /// One live browser tab of the pane: its record id, engine (nil: WebKit, the record's
    /// default), browser profile id and the page it shows (the live page's, else the record's).
    public nonisolated struct Candidate: Equatable, Sendable {
        public let id: String
        public let engine: String?
        public let profile: String
        public let shown: URL?

        public init(id: String, engine: String?, profile: String, shown: URL?) {
            (self.id, self.engine, self.profile, self.shown) = (id, engine, profile, shown)
        }
    }

    /// The address the page asked for.
    public let url: URL
    /// The engine of the page that asked (the new tab's engine).
    public let engine: String
    /// The browser profile id the new tab would get.
    public let profile: String

    /// `profile` nil is the default profile.
    public init(url: URL, engine: String, profile: String?) {
        (self.url, self.engine, self.profile) = (url, engine, profile ?? BrowserProfileRecord.defaultID)
    }

    /// The first of `candidates` (a pane's live browser tabs in strip order) that shows this page.
    public func first(in candidates: some Sequence<Candidate>) -> Candidate? {
        candidates.first { tab in
            tab.profile == profile && (tab.engine ?? CmuxNextDaemon.BrowserEngine.webkit.rawValue) == engine
                && tab.shown.map { Self.samePage($0, url) } == true
        }
    }

    /// Whether a foreground reuse of `tab` loads `url`: only its fragment differs from the page shown.
    public func navigates(_ tab: Candidate) -> Bool { tab.shown?.fragment != url.fragment }

    /// Whether two URLs are the same page: scheme and host compare
    /// case-insensitively, a trailing slash and the fragment are ignored.
    public static func samePage(_ a: URL, _ b: URL) -> Bool {
        func key(_ url: URL) -> String? {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            parts.fragment = nil
            parts.scheme = parts.scheme?.lowercased()
            parts.host = parts.host?.lowercased()
            if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
            if parts.path.isEmpty, parts.host != nil { parts.path = "/" }
            return parts.string
        }
        guard let left = key(a) else { return false }
        return left == key(b)
    }
}
