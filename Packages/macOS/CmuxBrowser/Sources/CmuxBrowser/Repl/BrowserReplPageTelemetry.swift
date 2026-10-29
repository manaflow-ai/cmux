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
        recipients(of: document, in: nil, among: sessionIDs) {
            BrowserReplDocumentAuthority(sessionID: $0, policy: policy($0) ?? BrowserReplDomainPolicy())
        }
    }

    /// The sessions, of `sessionIDs`, whose authority allows `document` in
    /// `tab` (``BrowserReplDocumentAuthority/verdict(_:)``).
    public func recipients(
        of document: BrowserReplFrameDocument,
        in tab: BrowserReplTabFacts?,
        among sessionIDs: [String],
        authority: (String) -> BrowserReplDocumentAuthority
    ) -> [String] {
        sessionIDs.filter { authority($0).verdict(BrowserReplAccess(.document(document), in: tab)) == .allowed }
    }
}
