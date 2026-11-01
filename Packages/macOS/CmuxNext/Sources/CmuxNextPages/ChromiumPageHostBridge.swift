import CmuxNextCompat
public import Foundation
import os

/// ``PageHostBridge`` for a Chromium page, through the DevTools protocol only (no render-process
/// code, so neither the Chromium fork nor the shim changes).
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
/// - ``evaluate(_:)`` runs scripts in order; the ones queued together go in one `Runtime.evaluate`.
@MainActor
public final class ChromiumPageHostBridge: PageHostBridge {
    public let engine = PageHostEngine.cef
    /// The binding the page script calls.
    nonisolated public static let bindingName = "__cmuxPageHost"
    /// The page function a reply calls.
    nonisolated public static let resolveName = "__cmuxPageHostResolve"
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
    private var scripts: [String] = []
    private var draining = false
    /// Number of messages answered (tests wait on it).
    public private(set) var answered = 0
    /// Binding calls waiting for their parse off the main actor, in arrival order.
    private var inbox: AsyncStream<String>.Continuation?
    private var reading: Task<Void, Never>?

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

    /// Adds the binding again for a new document (a no-op where it is still there).
    public func rebind() {
        guard let page else { return }
        // task-owner: one idempotent call on a page that may already be gone
        Task { _ = try? await page.devTools("Runtime.addBinding", params: ["name": Self.bindingName]) }
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

    nonisolated deinit {
        inbox?.finish()
        reading?.cancel()
    }

    public func uninstall() {
        handler = nil
        scripts.removeAll()
    }

    // MARK: Messages

    /// Handles one raw DevTools message of the page: true when it is a binding call for this
    /// bridge. The method and binding name come from the message's bytes on the caller's actor;
    /// the event and its payload (up to ``maximumPayloadBytes`` of JSON) are parsed off the main
    /// actor, and the calls are answered in the order they arrived.
    @discardableResult
    public func receive(devToolsMessage json: String) -> Bool {
        let head = DevToolsMessageHead(json: json)
        guard head.method == "Runtime.bindingCalled", head.contains(Self.bindingName) else { return false }
        if inbox == nil { startReading() }
        if case .dropped = inbox?.yield(json) { logger.error("page host binding call dropped: \(Self.maximumWaitingCalls) wait for their parse") }
        return true
    }

    /// The most binding calls that wait for their parse; a page that posts faster loses the newest.
    nonisolated static let maximumWaitingCalls = 4096

    private func startReading() {
        let (calls, inbox) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(Self.maximumWaitingCalls))
        self.inbox = inbox
        // task-owner: the bridge's binding-call reader; deinit finishes its stream and cancels it
        reading = Task { [weak self] in
            for await json in calls {
                let parsed = await Self.parse(json)
                guard let self else { return }
                switch parsed {
                case .call(let message, let context):
                    // task-owner: one message; its reply goes back to the context that sent it
                    Task { [weak self] in await self?.answer(message, context: context) }
                case .refused:
                    logger.error("page host binding payload refused")
                case .other:
                    break
                }
            }
        }
    }

    /// A binding call, parsed off the caller's actor.
    private nonisolated enum ParsedCall {
        case call(ChromiumPageHostWire.Message, context: Int)
        case refused
        /// Another binding's call, or no binding call at all.
        case other
    }

    /// The parse makes its result and keeps no reference to it, so the result is `sending`.
    @concurrent
    private nonisolated static func parse(_ json: String) async -> sending ParsedCall {
        guard let call = ChromiumPageHostWire.BindingCall(event: json), call.name == bindingName else { return .other }
        guard call.payload.utf8.count <= maximumPayloadBytes,
              let message = ChromiumPageHostWire.Message(payload: call.payload) else { return .refused }
        return .call(message, context: call.contextID)
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
        let expression = ChromiumPageHostWire.resolveExpression(seq: seq, reply: reply)
        _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
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
    /// binding exists wait in the page and go out once it appears. A call past
    /// ``maximumPayloadBytes`` is never sent (``receive(devToolsMessage:)`` drops it unanswered):
    /// it settles at once with a `cmux.protocol.too_large` error envelope.
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
          let retries = 0;
          const limit = \(maximumPayloadBytes);
          // UTF-8 bytes, counted only when the text could be past the limit.
          const tooLarge = (text) => {
            if (text.length > limit) return true;
            if (text.length * 3 <= limit) return false;
            let bytes = 0;
            for (let at = 0; at < text.length; at += 1) {
              const code = text.charCodeAt(at);
              bytes += code < 0x80 ? 1 : code < 0x800 || (code >= 0xd800 && code < 0xe000) ? 2 : 3;
            }
            return bytes > limit;
          };
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
          Object.defineProperty(globalThis, "\(resolveName)", {
            value: (seq, reply) => { const done = pending.get(seq); if (done) { pending.delete(seq); done(reply); } },
          });
          const handlers = {};
          for (const name of [\(names)]) {
            handlers[name] = {
              postMessage(body) {
                if (name !== \(replying)) { send(JSON.stringify({ name, body })); return undefined; }
                return new Promise((resolve) => {
                  const seq = next++;
                  const text = JSON.stringify({ name, seq, body });
                  if (tooLarge(text)) {
                    resolve({ t: "err", id: body?.id, code: "cmux.protocol.too_large", message: "The request is too large to send." });
                    return;
                  }
                  pending.set(seq, resolve);
                  send(text);
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
