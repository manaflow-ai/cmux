public import Foundation

/// The result of parsing a batch of incoming external URLs for one deep-link
/// kind (SSH or text), partitioned into accepted ``requests`` and rejected
/// ``parseErrors`` and reduced to the single ``resolution`` the app shell acts
/// on.
///
/// Lifted byte-faithfully from the duplicated reduce-and-guard preamble of the
/// legacy `AppDelegate+CmuxSSHURL` `handleCmuxSSHURLs(from:)` and
/// `handleCmuxTextURLs(from:)`: both parsed every URL, appended accepted
/// requests and rejected parse errors to two arrays (ignoring `.success(nil)`
/// non-matches), counted intents as `requests.count + parseErrors.count`, and
/// branched identically on that count. This type captures exactly that partition
/// and branch so the two app methods stop reimplementing it; the NSAlert
/// presentation and the single-request dispatch stay app-side, driven off
/// ``resolution``.
///
/// `Request` is the kind's parsed request value (``CmuxSSHURLRequest`` /
/// ``CmuxTextURLRequest``) and `ParseError` its rejection reason
/// (``CmuxSSHURLParseError`` / ``CmuxTextURLParseError``). The navigation kind
/// has a different, NSAlert-free control flow and is intentionally not modeled
/// here.
public struct CmuxDeepLinkDispatchPlan<Request, ParseError: Error> {
    /// The URLs the parser accepted, in encounter order.
    public let requests: [Request]
    /// The URLs the parser rejected, in encounter order.
    public let parseErrors: [ParseError]

    /// Parses `urls` with `parse`, partitioning each result into ``requests`` or
    /// ``parseErrors`` and dropping `.success(nil)` non-matches, matching the
    /// legacy per-URL `switch` exactly.
    ///
    /// - Parameters:
    ///   - urls: The incoming external URLs.
    ///   - parse: The kind's parser, applied to each URL (the app passes the
    ///     scheme-defaulted `parse(_:)` convenience).
    public init(
        parsing urls: [URL],
        with parse: (URL) -> Result<Request?, ParseError>
    ) {
        var requests: [Request] = []
        var parseErrors: [ParseError] = []
        for url in urls {
            switch parse(url) {
            case .success(.some(let request)):
                requests.append(request)
            case .success(nil):
                break
            case .failure(let error):
                parseErrors.append(error)
            }
        }
        self.requests = requests
        self.parseErrors = parseErrors
    }

    /// The number of deep-link intents: accepted requests plus rejected parse
    /// errors. A `.success(nil)` non-match contributes nothing.
    public var intentCount: Int {
        requests.count + parseErrors.count
    }

    /// What the app shell should do with this batch.
    public enum Resolution {
        /// No intent of this kind was present; the app shell falls through to
        /// the next deep-link kind (the legacy `guard … else { return false }`).
        case empty
        /// More than one intent was present; the app shell surfaces the kind's
        /// "only one link at a time" error.
        case multipleLinks
        /// Exactly one intent was present. The app shell shows `parseErrors`
        /// (zero or one, in order) and then dispatches `request` when non-nil,
        /// reproducing the legacy `for error in parseErrors { … }` followed by
        /// `if let request = requests.first { … }`.
        case single(parseErrors: [ParseError], request: Request?)
    }

    /// The reduced branch decision, byte-faithful to the legacy
    /// `intentCount`-based `if/else`.
    public var resolution: Resolution {
        let count = intentCount
        guard count > 0 else { return .empty }
        guard count == 1 else { return .multipleLinks }
        return .single(parseErrors: parseErrors, request: requests.first)
    }
}
