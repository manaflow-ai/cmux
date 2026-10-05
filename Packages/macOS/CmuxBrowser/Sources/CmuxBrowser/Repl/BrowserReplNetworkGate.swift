import Foundation
public import WebKit

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

/// Sends a tab's network events (``BrowserReplEventSpec/Delivery/network``)
/// only to the recipients whose ``BrowserReplDocumentAuthority`` allows the
/// document that sent the request, in the order they happened. A request,
/// its response and its end are reads of that document, as its console
/// messages are.
///
/// WebKit names a request's document by id (``BrowserReplNetworkSender``);
/// the gate knows a document by that id from a read of the tab's frame
/// tree (``readDocuments``), each frame's record carrying its document's
/// id. A recipient whose authority is not active in the tab (no policy, and
/// no local documents judged) gets every event at once. For one whose
/// authority is active, an event of a document the gate does not know yet
/// waits, with every event after it, for a fresh read; one whose document
/// that read does not name either (a document that went away first, a
/// request WebKit names no document for) does not reach that recipient
/// (fail closed). A load of a document is also judged by the URL it loads.
@MainActor
public final class BrowserReplNetworkGate<Event> {
    public typealias Deliver = @MainActor (_ event: Event, _ sessionIDs: [String]) -> Void

    private struct Pending {
        let event: Event
        let sender: BrowserReplNetworkSender
        let recipients: [String]
    }

    private let tab: @MainActor () -> BrowserReplTabFacts?
    private let authority: @MainActor (String) -> BrowserReplDocumentAuthority
    private let readDocuments: @MainActor () async -> [String: BrowserReplFrameDocument]
    private let deliver: Deliver
    /// Documents by WebKit's id, the most recently read last.
    private var documents: [String: BrowserReplFrameDocument] = [:]
    private var documentOrder: [String] = []
    /// Events waiting for a read, in the order they happened.
    private var backlog: [Pending] = []
    private var isReading = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// The documents the gate remembers; the oldest go first.
    static var maximumDocuments: Int { 1_024 }
    /// The events that may wait for a read; past it the waiting ones are
    /// judged with what the gate knows (fail closed) and sent.
    static var maximumBacklog: Int { 4_096 }

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
        self.tab = tab
        self.authority = authority
        self.readDocuments = readDocuments
        self.deliver = deliver
    }

    /// Sends `event`, which `sender` sent, to those of `recipients` whose
    /// authority allows `sender`'s document: now, or after a read of the
    /// frame tree, behind every event still waiting.
    public func send(_ event: Event, from sender: BrowserReplNetworkSender, to recipients: [String]) {
        let pending = Pending(event: event, sender: sender, recipients: recipients)
        if backlog.isEmpty, let sessions = sessions(for: pending, final: false) {
            deliver(event, sessions)
            return
        }
        if backlog.count >= Self.maximumBacklog {
            for waiting in backlog { deliver(waiting.event, sessions(for: waiting, final: true) ?? []) }
            backlog.removeAll()
            deliver(event, sessions(for: pending, final: true) ?? [])
            return
        }
        backlog.append(pending)
        guard !isReading else { return }
        isReading = true
        Task { @MainActor in await self.drain() }
    }

    /// Returns once every event sent so far has been delivered or dropped.
    public func idle() async {
        guard isReading || !backlog.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func drain() async {
        while !backlog.isEmpty {
            // Events that were waiting when the read started are judged by
            // it for good; later ones go on only while their documents are
            // known, else wait for the next read.
            let covered = backlog.count
            remember(await readDocuments())
            var sent = 0
            while sent < backlog.count {
                let pending = backlog[sent]
                guard let sessions = sessions(for: pending, final: sent < covered) else { break }
                deliver(pending.event, sessions)
                sent += 1
            }
            backlog.removeFirst(sent)
        }
        isReading = false
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func remember(_ read: [String: BrowserReplFrameDocument]) {
        for (id, document) in read {
            if documents.updateValue(document, forKey: id) == nil { documentOrder.append(id) }
        }
        if documentOrder.count > Self.maximumDocuments {
            let dropped = documentOrder.count - Self.maximumDocuments
            for id in documentOrder.prefix(dropped) { documents[id] = nil }
            documentOrder.removeFirst(dropped)
        }
    }

    /// The recipients `pending` reaches, or nil when one of them must wait
    /// for a read (never when `final`: then an unknown document reaches
    /// only recipients whose authority is not active).
    private func sessions(for pending: Pending, final: Bool) -> [String]? {
        let tab = tab()
        let document = pending.sender.documentID.flatMap { documents[$0] }
        var sessions: [String] = []
        for sessionID in pending.recipients {
            let authority = authority(sessionID)
            guard authority.isActive(in: tab) else {
                sessions.append(sessionID)
                continue
            }
            if let url = pending.sender.loadsDocument,
               authority.verdict(BrowserReplAccess(.load(url), in: tab)) != .allowed {
                continue
            }
            guard let document else {
                // A request WebKit names no document for can never be judged.
                if final || pending.sender.documentID == nil { continue }
                return nil
            }
            if authority.verdict(BrowserReplAccess(.document(document), in: tab)) == .allowed {
                sessions.append(sessionID)
            }
        }
        return sessions
    }
}

extension BrowserReplFrameDocument {
    /// The documents `frames` (a tree just read from `webView`) show, by
    /// WebKit's document id; frames whose record has no id are left out.
    @MainActor
    public static func byDocumentID(_ frames: [BrowserReplFrame], in webView: WKWebView) -> [String: BrowserReplFrameDocument] {
        var documents: [String: BrowserReplFrameDocument] = [:]
        for frame in frames {
            guard let info = frame.info, let id = BrowserReplFrameGate.documentID(of: info) else { continue }
            documents[id] = BrowserReplFrameDocument(info: info).withMakers(frame: info, in: webView)
        }
        return documents
    }
}
