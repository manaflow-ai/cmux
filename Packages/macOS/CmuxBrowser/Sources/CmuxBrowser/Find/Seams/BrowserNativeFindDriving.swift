import Foundation

/// An engine that finds text in its page natively and reports results asynchronously.
///
/// Chromium (CEF) conforms through its browser host: each ``find(_:forward:matchCase:findNext:)``
/// call is answered later by one or more find-result events, which the owner forwards to
/// ``BrowserNativeFindSession/receiveResult(count:activeOrdinal:isFinal:)``.
@MainActor
public protocol BrowserNativeFindDriving: AnyObject {
    /// Starts or continues a find request.
    /// - Parameters:
    ///   - text: The text to find.
    ///   - forward: `true` to search forward, `false` to search backward.
    ///   - matchCase: Whether the match is case-sensitive.
    ///   - findNext: `false` for a new search, `true` to step from the active match.
    /// - Returns: `false` when the engine cannot search now (no page yet, page closed); no
    ///   result event follows then.
    func find(_ text: String, forward: Bool, matchCase: Bool, findNext: Bool) -> Bool

    /// Ends the find session and removes the highlights.
    /// - Parameter clearSelection: Whether the active match's selection is removed as well.
    func stopFinding(clearSelection: Bool)
}
