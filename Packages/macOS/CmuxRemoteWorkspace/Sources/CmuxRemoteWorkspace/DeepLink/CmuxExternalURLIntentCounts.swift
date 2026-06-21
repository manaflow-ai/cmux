public import Foundation

/// How many SSH, navigation, and text deep-link intents a set of incoming URLs
/// carries, used by the app shell to decide whether exactly one external link
/// was requested and, when more than one was, which "only one link at a time"
/// error to surface.
///
/// An *intent* is a URL that the corresponding parser either accepted
/// (`.success(.some)`) or rejected (`.failure`); a URL the parser ignored
/// (`.success(nil)`, i.e. not that kind of link) does not count. This matches
/// the legacy classification exactly: a malformed SSH link still counts as one
/// SSH intent so the single-link guard can run before the parse error is shown.
///
/// Lifted byte-faithfully from the legacy `AppDelegate+CmuxSSHURL`
/// `CmuxExternalURLIntentCounts` struct and its `cmuxExternalURLIntentCounts(in:)`
/// reducer. The reduce, the three `parse` switch arms, and the
/// accept-or-reject-counts-as-intent rule are unchanged. The only deviation is
/// that the active deep-link scheme set is passed in explicitly: the parsers
/// live below the app's `AuthEnvironment` in the dependency graph, so the app
/// shell supplies its build-specific scheme set rather than the package reading
/// it. The NSAlert presentation of the resulting error stays app-side.
public struct CmuxExternalURLIntentCounts: Equatable, Sendable {
    /// Number of URLs the SSH parser accepted or rejected.
    public var ssh = 0
    /// Number of URLs the navigation parser accepted or rejected.
    public var navigation = 0
    /// Number of URLs the text parser accepted or rejected.
    public var text = 0

    /// Creates a count with the given per-kind totals (all default to zero).
    public init(ssh: Int = 0, navigation: Int = 0, text: Int = 0) {
        self.ssh = ssh
        self.navigation = navigation
        self.text = text
    }

    /// The total number of external-link intents across all three kinds.
    public var total: Int {
        ssh + navigation + text
    }

    /// Which "only one link at a time" error the app shell should present when
    /// `total` exceeds one.
    public enum MultipleLinksError: Equatable, Sendable {
        /// Surface the SSH-specific multiple-links error.
        case ssh
        /// Surface the generic text/external multiple-links error.
        case text
    }

    /// The multiple-links error to present, computed only when more than one
    /// intent is present. Returns ``MultipleLinksError/ssh`` exactly when every
    /// intent is an SSH intent (more than one SSH, no navigation, no text),
    /// otherwise ``MultipleLinksError/text``. `nil` when `total <= 1` (no
    /// multiple-links error applies).
    public var multipleLinksError: MultipleLinksError? {
        guard total > 1 else { return nil }
        if ssh > 1 && navigation == 0 && text == 0 {
            return .ssh
        }
        return .text
    }

    /// Classifies the deep-link intents carried by `urls`.
    ///
    /// - Parameters:
    ///   - urls: The incoming external URLs.
    ///   - supportedSchemes: The running build's active deep-link scheme set
    ///     (the app shell passes its `AuthEnvironment`-derived set).
    /// - Returns: The per-kind intent counts.
    public static func classify(
        urls: [URL],
        supportedSchemes: Set<String>
    ) -> CmuxExternalURLIntentCounts {
        urls.reduce(CmuxExternalURLIntentCounts()) { counts, url in
            var nextCounts = counts
            switch CmuxSSHURLRequest.parse(url, supportedSchemes: supportedSchemes) {
            case .success(.some), .failure:
                nextCounts.ssh += 1
            case .success(nil):
                break
            }
            switch CmuxNavigationURLRequest.parse(url, supportedSchemes: supportedSchemes) {
            case .success(.some), .failure:
                nextCounts.navigation += 1
            case .success(nil):
                break
            }
            switch CmuxTextURLRequest.parse(url, supportedSchemes: supportedSchemes) {
            case .success(.some), .failure:
                nextCounts.text += 1
            case .success(nil):
                break
            }
            return nextCounts
        }
    }
}
