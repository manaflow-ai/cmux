public import Foundation
import os

/// ``PageHostBridge`` for a Chromium page. Page messages come through the DevTools protocol; host
/// events and replies go back as scripts, or as data over the page push channel.
///
/// - `Runtime.addBinding` puts `__cmuxPageHost(string)` in the page's main world; a call arrives
///   as a `Runtime.bindingCalled` event with the caller's execution context.
/// - A script for every new document (``pageScript(handlers:)``) installs the WebKit-shaped API
///   on top of it (`window.webkit.messageHandlers.cmuxPage.postMessage(envelope)` resolving to the
///   reply), so the page does not know which engine shows it.
/// - Trust: the payload says nothing about its sender. For each message the bridge asks the
///   sender's own context for `location.href` and `window === window.top` (both unforgeable), and
///   ``PageHostTrust`` checks them as for WebKit.
/// - Replies go back into the sender's context only (`__cmuxPageHostResolve(seq, reply)`).
/// - With the page push channel (``PageChromiumPage/pushesToPage``, fork API 39) the router's
///   envelopes (``push(envelopes:)``) and the replies go to the page as strings
///   (``PageChromiumPage/push(_:)``) that the page script's receiver parses, the way Chrome's WebUI
///   pages get Mojo messages instead of `WebUI::CallJavascriptFunction` scripts
///   (content/browser/webui/web_ui_impl.cc): no script is compiled for them and none answers.
/// - Scripts and pushes leave in one FIFO, in the order they came; the scripts queued together go
///   in one `Runtime.evaluate`, and a push waits for the scripts before it to finish.
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
    /// (``ChromiumPageSetup``), then again for every committed document (``rebind()``).
    public static func setupCalls(handlers: [String], documentScripts: [String]) -> [(String, [String: any Sendable])] {
        var calls: [(String, [String: any Sendable])] = [
            // New-document scripts run only while the Page domain is on, and bindings reach worlds
            // made later only while the Runtime domain is on.
            ("Page.enable", [:]),
            ("Runtime.enable", [:]),
            ("Runtime.addBinding", ["name": bindingName]),
            ("Page.addScriptToEvaluateOnNewDocument", ["source": pageScript(handlers: handlers), "runImmediately": true]),
        ]
        for source in documentScripts {
            calls.append(("Page.addScriptToEvaluateOnNewDocument", ["source": source, "runImmediately": true]))
        }
        return calls
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
    }

    // MARK: Messages

    /// Handles one raw DevTools message of the page: true when it was this bridge's binding call.
    @discardableResult
    public func receive(devToolsMessage json: String) -> Bool {
        guard json.contains(Self.bindingName), let call = ChromiumPageHostWire.BindingCall(event: json),
              call.name == Self.bindingName else { return false }
        guard call.payload.utf8.count <= Self.maximumPayloadBytes,
              let message = ChromiumPageHostWire.Message(payload: call.payload) else {
            logger.error("page host binding payload refused")
            return true
        }
        // task-owner: one message; its reply goes back to the context that sent it
        // main-hop-allow: the trust check, the page's handler and the reply are the page's main-actor async calls (DevTools IPC, the provider op) with state checks between; the task only runs them
        Task { [weak self] in await self?.answer(message, context: call.contextID) }
        return true
    }

    private func answer(_ message: ChromiumPageHostWire.Message, context: Int) async {
        guard let page else { return }
        let senderJSON = try? await page.devTools("Runtime.evaluate", params: [
            "expression": "[location.href, window === window.top]",
            "contextId": context, "returnByValue": true, "silent": true,
        ])
        let sender = senderJSON.flatMap(ChromiumPageHostWire.Sender.init(evaluation:))
        let request = PageHostMessage(frameURL: sender?.url, isMainFrame: sender?.isTop ?? false, body: message.body)
        if message.name != PageHostTrust.handlerName {
            guard fireAndForget.contains(message.name), request.isMainFrame else { return }
            noteReached()
            onMessage?(message.name, message.body)
            return
        }
        guard let handler, let seq = message.seq else { return }
        noteReached()
        let reply = await handler(request)
        guard self.handler != nil else { return }
        // On the push channel the reply follows the envelopes the host sent before it, in the one FIFO;
        // only the main frame's document has the receiver, so a child frame's reply stays a script.
        // The push names the sender's document: a document that loaded since ignores it, as a
        // script for a context that is gone fails.
        if pushesEnvelopes, request.isMainFrame, let doc = message.doc {
            send(.reply(ChromiumPageHostWire.replyPush(seq: seq, doc: doc, reply: reply)))
        } else {
            let expression = ChromiumPageHostWire.resolveExpression(seq: seq, reply: reply)
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
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
    /// replies) and each of `handlers` (without) over the binding. Messages posted before the
    /// binding exists wait in the page and go out once it appears. Ends with
    /// ``pushReceiverScript``.
    public static func pageScript(handlers: [String]) -> String {
        let names = ([PageHostTrust.handlerName] + handlers).map(ChromiumPageHostWire.jsonString).joined(separator: ", ")
        let replying = ChromiumPageHostWire.jsonString(PageHostTrust.handlerName)
        return """
        (() => {
          if (globalThis.__cmuxPageHostInstalled) return;
          Object.defineProperty(globalThis, "__cmuxPageHostInstalled", { value: true });
          const pending = new Map();
          const queue = [];
          let next = 1;
          // This document's token: every document counts seq from 1, so a reply push names its document.
          const doc = (() => {
            const c = globalThis.crypto;
            if (typeof c?.randomUUID === "function") return c.randomUUID();
            if (typeof c?.getRandomValues === "function") return Array.from(c.getRandomValues(new Uint32Array(4)), (n) => n.toString(36)).join("-");
            return Math.random().toString(36).slice(2) + "-" + Date.now().toString(36);
          })();
          let retries = 0;
          const flush = () => {
            const binding = globalThis.\(bindingName);
            if (typeof binding !== "function") return false;
            while (queue.length) binding(queue.shift());
            return true;
          };
          const retry = () => {
            if (flush() || ++retries > 400) return;
            setTimeout(retry, 5);
          };
          const send = (text) => {
            queue.push(text);
            if (!flush() && queue.length === 1) { retries = 0; retry(); }
          };
          const resolve = (seq, reply) => { const done = pending.get(seq); if (done) { pending.delete(seq); done(reply); } };
          Object.defineProperty(globalThis, "\(resolveName)", { value: resolve });
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
        \(pushReceiverScript)
        })();
        """
    }

    /// The page script's half of the page push channel, inside ``pageScript(handlers:)`` where
    /// `resolve` settles a reply. Where the fork defines `cmuxPageListen` (the main frame of a
    /// cmux-page document, fork API 39) it registers the document's one receiver. A push is JSON:
    /// an array is one run of envelopes for the page's receiver (pageClient.ts registers it with
    /// ``listenName``; until it does, the runs wait here, at most ``maximumHeldPushes``), and
    /// `{"r": seq, "d": doc, "v": reply}` is a reply, settled only when `doc` is this document's token.
    nonisolated static let pushReceiverScript = """
          if (typeof globalThis.cmuxPageListen === "function") {
            let receiver = null;
            let held = [];
            const toPage = (envelopes) => {
              if (receiver) { receiver(envelopes); return; }
              if (held.length < \(maximumHeldPushes)) held.push(envelopes);
              else if (held.length === \(maximumHeldPushes)) { held.push(null); console.error("cmux page: no receiver; host events dropped"); }
            };
            globalThis.cmuxPageListen((text) => {
              const message = JSON.parse(text);
              if (Array.isArray(message)) toPage(message);
              else if (message && typeof message.r === "number" && message.d === doc) resolve(message.r, message.v);
            });
            Object.defineProperty(globalThis, "\(listenName)", {
              value: (fn) => {
                if (receiver || typeof fn !== "function") return false;
                receiver = fn;
                const waiting = held;
                held = [];
                for (const envelopes of waiting) if (envelopes) receiver(envelopes);
                return true;
              },
            });
          }
    """

    /// Runs of envelopes the page script keeps for a page that has no receiver yet.
    nonisolated static let maximumHeldPushes = 10_000
}
