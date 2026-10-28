public import Foundation
import os

/// ``PageHostBridge`` for a Chromium page. Page calls reach the host one of two ways:
///
/// - **Page channel** (fork API 29, ``PageChromiumPage/pageHostEvent``): the page script fires that
///   DOM event; the runtime's relay in an isolated world posts its text with `cmuxPost`, and it
///   arrives as ``PageChromiumEvent/pageHostPost(_:sender:)``, from the main frame only. One renderer
///   to browser message per post and no sender probe, as `chrome.send` reaches `WebUIImpl::OnWebUISend`
///   (content/browser/webui/web_ui_impl.cc). There the sender is the frame's last committed URL,
///   which the message's own per-frame pipe orders; here the commit and the post come on different
///   pipes, so the relay stamps each post with its document's URL, read in its isolated world, and
///   a post is judged only while that document is the one committed (``documentCommitted(_:)``).
/// - **DevTools binding** (any fork, and a post the relay did not take): `Runtime.addBinding` puts
///   `__cmuxPageHost(string)` in the page's main world; a call arrives as a `Runtime.bindingCalled`
///   event with the caller's execution context, and the bridge asks that context for
///   `location.href` and `window === window.top` once per post.
///
/// The page script (``pageScript(handlers:channelEvent:)``) installs the WebKit-shaped API
/// (`window.webkit.messageHandlers.cmuxPage.postMessage(envelope)` resolving to the reply), so the
/// page does not know which engine shows it. The posts of one task leave together at its microtask
/// checkpoint, as one call: a burst of calls is one message, and none waits for a frame.
/// The handlers of the page's messages start in post order (``start(_:)``), and calls then run
/// side by side. ``PageHostTrust`` checks each message as for WebKit. A reply goes back into the
/// sender's context (binding), or into the main frame with the sending document's id, so a reply
/// to a document that has gone resolves nothing in the next one (page channel).
///
/// With the page push channel (``PageChromiumPage/pushesToPage``, fork API 43) the router's
/// envelopes (``push(envelopes:)``) and the replies go to the page as strings
/// (``PageChromiumPage/push(_:)``) that the page script's receiver parses, the way Chrome's WebUI
/// pages get Mojo messages instead of `WebUI::CallJavascriptFunction` scripts
/// (content/browser/webui/web_ui_impl.cc): no script is compiled for them and none answers.
/// Scripts and pushes leave in one FIFO, in the order they came; the scripts queued together go
/// in one `Runtime.evaluate` (``evaluate(_:)``), and a push waits for the scripts before it to finish.
@MainActor
public final class ChromiumPageHostBridge: PageHostPushing {
    public let engine = PageHostEngine.cef
    /// The binding the page script calls.
    nonisolated public static let bindingName = "__cmuxPageHost"
    /// The page function a reply calls.
    nonisolated public static let resolveName = "__cmuxPageHostResolve"
    /// The page script function a page registers its envelope receiver with, on the push channel.
    nonisolated public static let listenName = "__cmuxPageHostListen"
    /// Longest message accepted (page calls are small; large data goes through replies and pushes).
    nonisolated public static let maximumPayloadBytes = 4 << 20
    /// The most UTF-16 units the page script joins into one post; a longer call goes alone.
    nonisolated static let maximumPostCharacters = 1 << 20

    /// A page channel post held for its document's commit (``documentCommitted(_:)``).
    public struct HeldPost {
        let text: String
        let sender: URL
    }

    /// One handler start, in post order: a fire-and-forget message or a call.
    private enum Start {
        case message(String, Any)
        case call(Int)
    }

    /// One page call waiting for its handler.
    private struct Call {
        var request: PageHostMessage
        var seq: Int
        var document: String?
        /// The sender's execution context (binding); nil: the main frame (page channel).
        var context: Int?
    }

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-host.chromium")
    private weak var page: (any PageChromiumPage)?
    /// Handler names without a reply (the paint probe): their messages go to ``onMessage``.
    private let fireAndForget: [String]
    private var handler: PageHostHandler?
    /// Messages of the ``fireAndForget`` handlers, after the trust check: (name, body).
    public var onMessage: ((String, Any) -> Void)?
    /// Called once, when the first trusted message arrives: the page reached the host.
    public var onFirstMessage: (() -> Void)?
    private var reachedHost = false

    /// One thing to send to the page, in order.
    private enum Outgoing {
        case script(String)
        /// A run of the router's envelopes.
        case envelopes(String)
        /// A reply push. It names the document it answers, so it never needs dropping: the
        /// receiver of any other document ignores it.
        case reply(String)

        var isEnvelopes: Bool {
            guard case .envelopes = self else { return false }
            return true
        }

        var pushText: String? {
            switch self {
            case .script: nil
            case .envelopes(let text), .reply(let text): text
            }
        }
    }
    private var outgoing: [Outgoing] = []
    private var draining = false
    /// The main-frame document the page last committed: a page channel post is judged while its
    /// stamped sender is this document (``isCommitted(_:)``).
    private var committedDocument: URL?
    /// Page channel posts whose sender is not the committed document: a newer document's, judged
    /// when its commit arrives, since the commit's DevTools event and the post come on different pipes.
    private var earlyPosts: [HeldPost] = []
    /// The most posts kept waiting for their commit; more are refused.
    nonisolated static let maximumEarlyPosts = 64
    /// Handler starts waiting for the ones before them (``start(_:)``).
    private var starts: [Start] = []
    /// Calls waiting for their handler, by the bridge's own id.
    private var calls: [Int: Call] = [:]
    private var nextCall = 0
    /// Number of messages answered (tests wait on it).
    public private(set) var answered = 0

    /// - Parameters:
    ///   - page: The Chromium page.
    ///   - fireAndForget: Extra `window.webkit.messageHandlers` names whose messages need no reply.
    public init(page: any PageChromiumPage, fireAndForget: [String] = []) {
        self.page = page
        self.fireAndForget = fireAndForget
    }

    /// The DevTools calls that set the page up, in order: run them before the first document loads
    /// (``ChromiumPageSetup``), then again for every committed document (``rebind()``). The page
    /// script and the document scripts go in one new-document script, each in its own block as
    /// ``batch(_:)`` runs scripts, so the setup is four round trips however many scripts the page has.
    ///
    /// - Parameters:
    ///   - handlers: Extra `window.webkit.messageHandlers` names whose messages need no reply.
    ///   - documentScripts: The page's own new-document scripts, in order.
    ///   - channelEvent: The page's page channel event (``PageChromiumPage/pageHostEvent``); nil: none.
    public static func setupCalls(handlers: [String], documentScripts: [String],
                                  channelEvent: String? = nil) -> [(String, [String: any Sendable])] {
        let source = batch([pageScript(handlers: handlers, channelEvent: channelEvent)] + documentScripts)
        return [
            // New-document scripts run only while the Page domain is on, and bindings reach worlds
            // made later only while the Runtime domain is on.
            ("Page.enable", [:]),
            ("Runtime.enable", [:]),
            ("Runtime.addBinding", ["name": bindingName]),
            ("Page.addScriptToEvaluateOnNewDocument", ["source": source, "runImmediately": true]),
        ]
    }

    public func install(_ handler: @escaping PageHostHandler) {
        guard self.handler == nil else { return }
        self.handler = handler
    }

    /// A new document committed: the binding goes in again (a no-op where it is still there), and
    /// envelope runs still queued for the old document are dropped (the router dropped them too).
    public func rebind() {
        outgoing.removeAll(where: \.isEnvelopes)
        guard let page else { return }
        // task-owner: one idempotent call on a page that may already be gone
        // main-hop-allow: devTools is the page's main-actor async DevTools call (its IPC runs in Chromium); the task only sends it, and nobody reads its answer
        Task { _ = try? await page.devTools("Runtime.addBinding", params: ["name": Self.bindingName]) }
    }

    /// A main-frame document committed at `url`, whichever it is (one the page host then sends
    /// away too): its posts are judged from now on. Returns its posts that came before the commit;
    /// pass them to ``replay(_:)`` once the view has taken the commit, so its reset for the new
    /// document does not undo them. A cmux page's commit drops the held posts of every other
    /// document (one that has gone); a commit of no cmux page (the initial `about:blank`) keeps them.
    public func documentCommitted(_ url: URL?) -> [HeldPost] {
        committedDocument = url
        guard Self.posts(from: url) else { return [] }
        let held = earlyPosts.filter { isCommitted($0.sender) }
        earlyPosts.removeAll()
        return held
    }

    /// Delivers the posts ``documentCommitted(_:)`` returned, in the order they came.
    public func replay(_ posts: [HeldPost]) {
        for post in posts { receive(pageHostPost: post.text, sender: post.sender) }
    }

    /// Whether a document at `url` can post on the page channel: a cmux page (the relay runs nowhere else).
    nonisolated static func posts(from url: URL?) -> Bool { url?.scheme?.lowercased() == PageDescriptor.scheme }

    /// Whether `sender` is the committed document: a cmux page of the same origin, the unit
    /// ``PageHostTrust`` judges (``PageDescriptor/owns(_:)``); the page's own `pushState` and
    /// fragment changes keep it.
    private func isCommitted(_ sender: URL) -> Bool {
        guard let committedDocument, Self.posts(from: committedDocument), Self.posts(from: sender) else { return false }
        return sender.host?.lowercased() == committedDocument.host?.lowercased() && sender.port == committedDocument.port
    }

    public func evaluate(_ script: String) {
        send(.script(script))
    }

    /// Whether the router's envelopes go to the page as data (the page push channel is on).
    public var pushesEnvelopes: Bool { page?.pushesToPage == true }

    /// One run of the router's envelopes as their JSON array (``PageRouter/receiveManyData(_:)``),
    /// after everything sent before it. The page script hands it to the page's receiver.
    public func push(envelopes json: String) {
        send(.envelopes(json))
    }

    /// A push with nothing ahead of it goes in this turn; anything else waits its turn in the FIFO.
    private func send(_ item: Outgoing) {
        if let text = item.pushText, !draining, outgoing.isEmpty, let page {
            page.push(text)
            return
        }
        outgoing.append(item)
        guard !draining else { return }
        draining = true
        // task-owner: the bridge's script FIFO; it ends when the queue is empty or the page is gone
        // main-hop-allow: the drain awaits the page's main-actor async DevTools evaluate per batch, in FIFO order; its main parts only take the next batch
        Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { draining = false }
        while !outgoing.isEmpty {
            guard let page else {
                outgoing.removeAll()
                return
            }
            if let text = outgoing.first?.pushText {
                outgoing.removeSubrange(..<1)
                page.push(text)
                continue
            }
            // Every script queued so far goes in one round trip (a streaming reply queued one push
            // per frame); scripts queued while it runs go in the next.
            let batch = takeBatch()
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": Self.batch(batch), "silent": true])
        }
    }

    /// The scripts at the head of the queue, up to the first push and ``maximumBatchBytes`` (at least one).
    private func takeBatch() -> [String] {
        var bytes = 0
        var batch: [String] = []
        for item in outgoing {
            guard case .script(let script) = item else { break }
            bytes += script.utf8.count
            if !batch.isEmpty, bytes > Self.maximumBatchBytes { break }
            batch.append(script)
        }
        outgoing.removeSubrange(..<batch.count)
        return batch
    }

    /// The most script bytes sent in one `Runtime.evaluate`.
    nonisolated static let maximumBatchBytes = 2 << 20

    /// One expression that runs `scripts` in order, each in its own block, so that one that throws
    /// does not stop the ones after it (as separate evaluations did) and their declarations do not meet.
    /// A single script is sent as it is.
    nonisolated static func batch(_ scripts: [String]) -> String {
        guard scripts.count > 1 else { return scripts.first ?? "" }
        return scripts.map { "try {\n\($0)\n} catch (e) { console.error(e) }" }.joined(separator: "\n")
    }

    public func uninstall() {
        handler = nil
        outgoing.removeAll()
        calls.removeAll()
        starts.removeAll()
        earlyPosts.removeAll()
    }

    // MARK: Messages

    /// Handles one raw DevTools message of the page: true when it was this bridge's binding call.
    @discardableResult
    public func receive(devToolsMessage json: String) -> Bool {
        guard json.contains(Self.bindingName), let call = ChromiumPageHostWire.BindingCall(event: json),
              call.name == Self.bindingName else { return false }
        guard call.payload.utf8.count <= Self.maximumPayloadBytes else {
            logger.error("page host binding payload refused")
            return true
        }
        let payload = call.payload
        let context = call.contextID
        // task-owner: one binding call; its sender is asked once, and its replies go back to that context
        // main-hop-allow: the sender query is the page's main-actor async DevTools evaluate (its IPC runs in Chromium); the task only awaits it and then delivers in this actor's order
        Task { [weak self] in await self?.askSender(payload, context: context) }
        return true
    }

    /// Handles one page channel post of the page's main frame (``PageChromiumEvent/pageHostPost(_:sender:)``),
    /// sent by the document at `sender` (the relay's stamp, which the page's own world cannot change).
    /// While that document is the committed one, its messages start their handlers in post order;
    /// else the post waits for that document's commit (``documentCommitted(_:)``).
    public func receive(pageHostPost text: String, sender: URL) {
        guard text.utf8.count <= Self.maximumPayloadBytes else {
            logger.error("page host post refused")
            return
        }
        guard isCommitted(sender) else {
            guard earlyPosts.count < Self.maximumEarlyPosts else { return logger.error("page host post before the commit refused") }
            earlyPosts.append(HeldPost(text: text, sender: sender))
            return
        }
        deliver(text, sender: ChromiumPageHostWire.Sender(url: sender, isTop: true), context: nil)
    }

    /// Asks the sender (a binding call's context) for its URL, then delivers and answers.
    private func askSender(_ payload: String, context: Int) async {
        guard let page else { return }
        let params: [String: any Sendable] = ["expression": "[location.href, window === window.top]", "contextId": context,
                                              "returnByValue": true, "silent": true]
        let senderJSON = try? await page.devTools("Runtime.evaluate", params: params)
        deliver(payload, sender: senderJSON.flatMap(ChromiumPageHostWire.Sender.init(evaluation:)), context: context)
    }

    /// Starts the handler of each message of `payload`, in order (``start(_:)``).
    private func deliver(_ payload: String, sender: ChromiumPageHostWire.Sender?, context: Int?) {
        guard let messages = ChromiumPageHostWire.messages(payload: payload) else {
            logger.error("page host payload refused")
            return
        }
        for message in messages {
            let request = PageHostMessage(frameURL: sender?.url, isMainFrame: sender?.isTop ?? false, body: message.body)
            if message.name != PageHostTrust.handlerName {
                guard fireAndForget.contains(message.name), request.isMainFrame else { continue }
                noteReached()
                start(.message(message.name, message.body))
                continue
            }
            guard handler != nil, let seq = message.seq else { continue }
            noteReached()
            nextCall += 1
            calls[nextCall] = Call(request: request, seq: seq, document: message.doc, context: context)
            start(.call(nextCall))
        }
    }

    /// Starts one handler after every handler before it. A fire-and-forget message runs in this
    /// turn while no start waits; a call, and every message after one, waits in ``starts`` and
    /// starts in a task of its own that takes the oldest waiting start, so handlers start in post
    /// order whatever order the tasks run in, and a slow call holds back no other.
    private func start(_ next: Start) {
        if case .message(let name, let body) = next, starts.isEmpty {
            onMessage?(name, body)
            return
        }
        starts.append(next)
        // main-hop-allow: a page call's handler is main-actor async (PageHostHandler); this task only starts the oldest waiting handler and evaluates its reply
        // task-owner: one handler start of a page post; it ends with that handler's reply, or at once once the bridge is uninstalled
        Task { [weak self] in await self?.startOldest() }
    }

    private func startOldest() async {
        guard !starts.isEmpty else { return }
        switch starts.removeFirst() {
        case .message(let name, let body): onMessage?(name, body)
        case .call(let id): await run(id)
        }
    }

    private func run(_ id: Int) async {
        guard let call = calls.removeValue(forKey: id), let handler else { return }
        let reply = await handler(call.request)
        guard self.handler != nil, let page else { return }
        // On the push channel the reply follows the envelopes the host sent before it, in the one FIFO;
        // only the main frame's document has the receiver, so a child frame's reply stays a script.
        // The push names the sender's document: a document that loaded since ignores it, as a
        // script for a context that is gone fails.
        if pushesEnvelopes, call.request.isMainFrame, let doc = call.document {
            send(.reply(ChromiumPageHostWire.replyPush(seq: call.seq, doc: doc, reply: reply)))
        } else if let context = call.context {
            let expression = ChromiumPageHostWire.resolveExpression(seq: call.seq, reply: reply, document: call.document)
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
        } else {
            // The main frame's world, in order with the pushes; the document token keeps it out of a newer document.
            evaluate(ChromiumPageHostWire.resolveExpression(seq: call.seq, reply: reply, document: call.document))
        }
        answered += 1
    }

    private func noteReached() {
        guard !reachedHost else { return }
        reachedHost = true
        onFirstMessage?()
    }
}
