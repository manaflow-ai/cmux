public import Foundation
import os

/// ``PageHostBridge`` for a Chromium page. Page calls reach the host one of two ways:
///
/// - **Page channel** (fork API 29, ``PageChromiumPage/pageHostEvent``): the page script fires that
///   DOM event; the runtime's relay in an isolated world posts its text with `cmuxPost`, and it
///   arrives as ``PageChromiumEvent/pageHostPost(_:)``, from the main frame only. One renderer to
///   browser message per post and no sender probe, as `chrome.send` reaches `WebUIImpl::OnWebUISend`
///   (content/browser/webui/web_ui_impl.cc), which judges the sender by its frame's last committed
///   URL: here the document the page last committed (``documentCommitted(_:)``).
/// - **DevTools binding** (any fork, and a post the relay did not take): `Runtime.addBinding` puts
///   `__cmuxPageHost(string)` in the page's main world; a call arrives as a `Runtime.bindingCalled`
///   event with the caller's execution context, and the bridge asks that context for
///   `location.href` and `window === window.top` once per call.
///
/// The page script (``pageScript(handlers:channelEvent:)``) installs the WebKit-shaped API
/// (`window.webkit.messageHandlers.cmuxPage.postMessage(envelope)` resolving to the reply), so the
/// page does not know which engine shows it. The posts of one task leave together at its microtask
/// checkpoint, as one call: a burst of calls is one message, and none waits for a frame.
/// ``PageHostTrust`` checks each message as for WebKit. A reply goes back into the sender's context
/// (binding), or into the main frame with the sending document's id, so a reply to a document that
/// has gone resolves nothing in the next one (page channel).
/// ``evaluate(_:)`` runs scripts in order; the ones queued together go in one `Runtime.evaluate`.
@MainActor
public final class ChromiumPageHostBridge: PageHostBridge {
    public let engine = PageHostEngine.cef
    /// The binding the page script calls.
    nonisolated public static let bindingName = "__cmuxPageHost"
    /// The page function a reply calls.
    nonisolated public static let resolveName = "__cmuxPageHostResolve"
    /// Longest message accepted (page calls are small; large data goes through replies and pushes).
    nonisolated public static let maximumPayloadBytes = 4 << 20
    /// The most UTF-16 units the page script joins into one post; a longer call goes alone.
    nonisolated static let maximumPostCharacters = 1 << 20

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
    private var scripts: [String] = []
    private var draining = false
    /// The main-frame document the page last committed, the sender of its page channel posts
    /// (`.some(nil)`: one with no URL, which no page owns); nil before the first commit is heard.
    private var committedDocument: URL??
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

    /// Adds the binding again for a new document (a no-op where it is still there).
    public func rebind() {
        guard let page else { return }
        // task-owner: one idempotent call on a page that may already be gone
        Task { _ = try? await page.devTools("Runtime.addBinding", params: ["name": Self.bindingName]) }
    }

    /// A main-frame document committed at `url`, whichever it is (one the page host then sends
    /// away too): the page channel posts after it are its own, judged by `url`.
    public func documentCommitted(_ url: URL?) {
        committedDocument = .some(url)
    }

    public func evaluate(_ script: String) {
        scripts.append(script)
        guard !draining else { return }
        draining = true
        // task-owner: the bridge's script FIFO; it ends when the queue is empty or the page is gone
        Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { draining = false }
        while !scripts.isEmpty {
            guard let page else {
                scripts.removeAll()
                return
            }
            // Everything queued so far goes in one round trip (a streaming reply queues one push per
            // frame); scripts queued while it runs go in the next.
            let batch = takeBatch()
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": Self.batch(batch), "silent": true])
        }
    }

    /// The scripts at the head of the queue, up to ``maximumBatchBytes`` (at least one).
    private func takeBatch() -> [String] {
        var bytes = 0
        var count = 0
        for script in scripts {
            bytes += script.utf8.count
            if count > 0, bytes > Self.maximumBatchBytes { break }
            count += 1
        }
        defer { scripts.removeFirst(count) }
        return Array(scripts.prefix(count))
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
        scripts.removeAll()
        calls.removeAll()
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
        Task { [weak self] in await self?.askSender(payload, context: context) }
        return true
    }

    /// Handles one page channel post of the page's main frame (``PageChromiumEvent/pageHostPost(_:)``):
    /// its messages reach their handlers in this turn, sent by the document the page last committed.
    /// Before the first commit is heard (its DevTools event and the post come on different pipes),
    /// the main frame is asked once, as for a binding call.
    public func receive(pageHostPost text: String) {
        guard text.utf8.count <= Self.maximumPayloadBytes else {
            logger.error("page host post refused")
            return
        }
        guard let committedDocument else {
            // task-owner: one post before the first commit; its sender is asked once
            Task { [weak self] in await self?.askSender(text, context: nil) }
            return
        }
        deliver(text, sender: ChromiumPageHostWire.Sender(url: committedDocument, isTop: true), context: nil)
    }

    /// Asks the sender (a binding call's context, or the main frame for nil) for its URL, then delivers.
    private func askSender(_ payload: String, context: Int?) async {
        guard let page else { return }
        var params: [String: any Sendable] = ["expression": "[location.href, window === window.top]", "returnByValue": true, "silent": true]
        if let context { params["contextId"] = context }
        let senderJSON = try? await page.devTools("Runtime.evaluate", params: params)
        deliver(payload, sender: senderJSON.flatMap(ChromiumPageHostWire.Sender.init(evaluation:)), context: context)
    }

    /// Hands each message of `payload` to its handler, in order: a fire-and-forget one in this turn,
    /// a call once its handler answers.
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
                onMessage?(message.name, message.body)
                continue
            }
            guard handler != nil, let seq = message.seq else { continue }
            noteReached()
            start(Call(request: request, seq: seq, document: message.document, context: context))
        }
    }

    private func start(_ call: Call) {
        nextCall += 1
        let id = nextCall
        calls[id] = call
        // task-owner: one page call; its reply goes back to the document that sent it
        Task { [weak self] in await self?.run(id) }
    }

    private func run(_ id: Int) async {
        guard let call = calls.removeValue(forKey: id), let handler else { return }
        let reply = await handler(call.request)
        guard self.handler != nil, let page else { return }
        let expression = ChromiumPageHostWire.resolveExpression(seq: call.seq, reply: reply, document: call.document)
        if let context = call.context {
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
        } else {
            // The main frame's world, in order with the pushes; the document id keeps it out of a newer document.
            evaluate(expression)
        }
        answered += 1
    }

    private func noteReached() {
        guard !reachedHost else { return }
        reachedHost = true
        onFirstMessage?()
    }

    // MARK: Page script

    /// Installs `window.webkit.messageHandlers.<name>` for ``PageHostTrust/handlerName`` (with
    /// replies) and each of `handlers` (without). The posts of one task leave together at its
    /// microtask checkpoint as one call (a JSON array of several, up to ``maximumPostCharacters``):
    /// on the page channel when `channelEvent` is set and its relay takes the post, else on the
    /// binding, which the document then keeps, so its posts stay in order. Posts made before either
    /// exists wait in the page and go out once one does.
    ///
    /// - Parameters:
    ///   - handlers: Extra handler names whose messages need no reply.
    ///   - channelEvent: The page channel event (``PageChromiumPage/pageHostEvent``); nil: the binding only.
    public static func pageScript(handlers: [String], channelEvent: String? = nil) -> String {
        let names = ([PageHostTrust.handlerName] + handlers).map(ChromiumPageHostWire.jsonString).joined(separator: ", ")
        let replying = ChromiumPageHostWire.jsonString(PageHostTrust.handlerName)
        let event = channelEvent.map(ChromiumPageHostWire.jsonString) ?? "null"
        return """
        (() => {
          if (globalThis.__cmuxPageHostInstalled) return;
          Object.defineProperty(globalThis, "__cmuxPageHostInstalled", { value: true });
          const channelEvent = \(event);
          const doc = Math.random().toString(36).slice(2) + Date.now().toString(36);
          const pending = new Map();
          const queue = [];
          let next = 1;
          let retries = 0;
          let waiting = false;
          let bindingUsed = false;
          const viaChannel = (text) => channelEvent !== null && !bindingUsed
            && !document.dispatchEvent(new CustomEvent(channelEvent, { detail: text, cancelable: true }));
          const viaBinding = (text) => {
            const binding = globalThis.\(bindingName);
            if (typeof binding !== "function") return false;
            binding(text);
            bindingUsed = true;
            return true;
          };
          const flush = () => {
            while (queue.length) {
              let size = queue[0].length;
              let count = 1;
              while (count < queue.length && size + queue[count].length <= \(maximumPostCharacters)) size += queue[count++].length;
              const text = count === 1 ? queue[0] : "[" + queue.slice(0, count).join(",") + "]";
              if (!viaChannel(text) && !viaBinding(text)) return false;
              queue.splice(0, count);
            }
            return true;
          };
          const drain = () => {
            if (flush() || ++retries > 400) { waiting = false; return; }
            setTimeout(drain, 5);
          };
          const send = (text) => {
            queue.push(text);
            if (waiting) return;
            waiting = true;
            retries = 0;
            queueMicrotask(drain);
          };
          Object.defineProperty(globalThis, "\(resolveName)", {
            value: (seq, reply, from) => {
              if (from !== undefined && from !== doc) return;
              const done = pending.get(seq);
              if (done) { pending.delete(seq); done(reply); }
            },
          });
          const handlers = {};
          for (const name of [\(names)]) {
            handlers[name] = {
              postMessage(body) {
                if (name !== \(replying)) { send(JSON.stringify({ name, body })); return undefined; }
                return new Promise((resolve) => {
                  const seq = next++;
                  pending.set(seq, resolve);
                  send(JSON.stringify({ name, seq, doc, body }));
                });
              },
            };
          }
          const webkit = globalThis.webkit ?? {};
          globalThis.webkit = { ...webkit, messageHandlers: { ...(webkit.messageHandlers ?? {}), ...handlers } };
        })();
        """
    }
}
