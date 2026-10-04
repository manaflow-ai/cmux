/// Console messages and uncaught errors of a tab's page, which every session
/// attached to the tab receives as events (`console`, `pageerror`) and keeps
/// for `page.consoleMessages()` and `page.errors()`.
public struct BrowserReplPageTelemetry: Sendable {
    public init() {}

    /// The sessions, of `sessionIDs`, that receive an event from `document`
    /// (the frame that sent it, as WebKit recorded it), given each session's
    /// domain policy (`nil`: none). Seam: every session.
    public func recipients(
        of document: BrowserReplFrameDocument,
        among sessionIDs: [String],
        policy: (String) -> BrowserReplDomainPolicy?
    ) -> [String] {
        sessionIDs
    }
}
