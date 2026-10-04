/// Console messages and uncaught errors of a tab's page, which every session
/// attached to the tab receives as events (`console`, `pageerror`) and keeps
/// for `page.consoleMessages()` and `page.errors()`.
public struct BrowserReplPageTelemetry: Sendable {
    public init() {}

    /// The sessions, of `sessionIDs`, that receive an event from `document`
    /// (the frame that sent it, as WebKit recorded it), given each session's
    /// domain policy (`nil`: none): those whose policy allows the document.
    /// The policy refuses a session's reads of a page it blocks, and the
    /// page's console text and errors are reads of it.
    public func recipients(
        of document: BrowserReplFrameDocument,
        among sessionIDs: [String],
        policy: (String) -> BrowserReplDomainPolicy?
    ) -> [String] {
        sessionIDs.filter { policy($0)?.blockReason(document: document) == nil }
    }
}
