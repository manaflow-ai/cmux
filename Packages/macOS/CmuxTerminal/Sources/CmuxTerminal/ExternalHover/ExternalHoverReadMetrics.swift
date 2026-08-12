import Foundation

/// (C) ExternalHover diagnostics — review round3 B3: `resolveFully`'s
/// `stage=read` log line reports three purely string-derived facts about
/// the text it just read (`textBytes`/`newlineCount`/`rawEntryCount` — see
/// `logRead`'s own doc). Pulling their computation out into this pure
/// value type + an injectable calculator (`ExternalHoverWorkService
/// .ReadMetricsCalculator`) is what makes "gate OFF ⇒ this computation
/// never runs" an observable, countable fact for a test, rather than
/// something only visible by reading `resolveFully`'s source and trusting
/// the `if diagnosticsOn` block really does gate it.
public struct ExternalHoverReadMetrics: Sendable, Equatable {
    public let textBytes: Int
    public let newlineCount: Int
    public let rawEntryCount: Int

    public init(textBytes: Int, newlineCount: Int, rawEntryCount: Int) {
        self.textBytes = textBytes
        self.newlineCount = newlineCount
        self.rawEntryCount = rawEntryCount
    }
}

extension ExternalHoverWorkService {
    /// The REAL, allocation-free computation: `rawEntryCount` is derived
    /// arithmetically from `newlineCount` (N delimiters ⇒ N+1 pieces,
    /// matching what a bare `text.split(separator: "\n",
    /// omittingEmptySubsequences: false)` would yield) rather than
    /// actually calling `.split` and materializing that array — review
    /// round2 B4's fix, preserved here as the production default for
    /// `ReadMetricsCalculator` so a test can wrap this exact function with
    /// a counting double and still observe real values, instead of
    /// injecting a synthetic stand-in that proves nothing about the real
    /// formula.
    public static func defaultReadMetrics(_ text: String) -> ExternalHoverReadMetrics {
        let newlineCount = text.lazy.filter { $0 == "\n" }.count
        return ExternalHoverReadMetrics(
            textBytes: text.utf8.count,
            newlineCount: newlineCount,
            rawEntryCount: text.isEmpty ? 0 : newlineCount + 1
        )
    }
}
