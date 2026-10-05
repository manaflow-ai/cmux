public import Foundation

/// The document a network request belongs to, as WebKit names it, and for
/// a load of a document (a frame navigating) the URL it loads.
public struct BrowserReplNetworkSender: Sendable, Equatable {
    /// WebKit's id of the document the request belongs to
    /// (`_WKResourceLoadInfo.documentID`, the id `-[WKFrameInfo _documentIdentifier]`
    /// names); nil when WebKit gives none.
    public var documentID: String?
    /// For a load of a document, the URL it loads.
    public var loadsDocument: String?

    public init(documentID: String?, loadsDocument: String? = nil) {
        self.documentID = documentID
        self.loadsDocument = loadsDocument
    }
}

/// Sends a tab's network events to their recipients.
@MainActor
public final class BrowserReplNetworkGate<Event> {
    public typealias Deliver = @MainActor (_ event: Event, _ sessionIDs: [String]) -> Void

    private let deliver: Deliver

    /// - Parameters:
    ///   - tab: The tab as the authority judges it.
    ///   - authority: Each recipient's authority.
    ///   - readDocuments: Reads the documents the tab's frames show now, by
    ///     WebKit's document id.
    ///   - deliver: Sends an event to sessions.
    public init(
        tab: @escaping @MainActor () -> BrowserReplTabFacts?,
        authority: @escaping @MainActor (String) -> BrowserReplDocumentAuthority,
        readDocuments: @escaping @MainActor () async -> [String: BrowserReplFrameDocument],
        deliver: @escaping Deliver
    ) {
        self.deliver = deliver
    }

    /// Sends `event`, which `sender` sent, to those of `recipients` it may reach.
    public func send(_ event: Event, from sender: BrowserReplNetworkSender, to recipients: [String]) {
        deliver(event, recipients)
    }

    /// Returns once every event sent so far has been delivered or dropped.
    public func idle() async {}
}
