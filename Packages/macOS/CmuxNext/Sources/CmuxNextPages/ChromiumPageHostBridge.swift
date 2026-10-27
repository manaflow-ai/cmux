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
public nonisolated enum AgentPageUploadError: Error, Equatable, Sendable { case invalidBlob }

@MainActor
public final class ChromiumPageHostBridge: PageHostBridge {
    public let engine = PageHostEngine.cef
    /// The binding the page script calls.
    nonisolated public static let bindingName = "__cmuxPageHost"
    /// The page function a reply calls.
    nonisolated public static let resolveName = "__cmuxPageHostResolve"
    /// Longest message accepted (page calls are small; large data goes through replies and pushes).
    nonisolated public static let maximumPayloadBytes = 4 << 20

    public typealias UploadHandler = @MainActor (_ page: any PageChromiumPage, _ context: Int, _ params: [String: Any], _ chunks: AsyncThrowingStream<Data, any Error>) async -> [String: Any]?
    public typealias UploadQueryHandler = @MainActor (_ op: String, _ context: Int, _ params: [String: Any]) async -> [String: Any]?
    /// Set by the pane host. The page passes only an upload token; the host reads the Blob in its context.
    public var uploadHandler: UploadHandler?
    public var uploadQueryHandler: UploadQueryHandler?

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-host.chromium")
    private weak var page: (any PageChromiumPage)?
    private let descriptor: PageDescriptor?
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

    /// - Parameters:
    ///   - page: The Chromium page.
    ///   - fireAndForget: Extra `window.webkit.messageHandlers` names whose messages need no reply.
    public init(page: any PageChromiumPage, fireAndForget: [String] = [], uploadHandler: UploadHandler? = nil,
                uploadQueryHandler: UploadQueryHandler? = nil, descriptor: PageDescriptor? = nil) {
        self.page = page
        self.fireAndForget = fireAndForget
        self.uploadHandler = uploadHandler
        self.uploadQueryHandler = uploadQueryHandler
        self.descriptor = descriptor
    }

    /// The DevTools calls that set the page up, in order: run them before the first document loads
    /// (``ChromiumPageSetup``), then again for every committed document (``rebind()``).
    public static func setupCalls(handlers: [String], documentScripts: [String], supportsUploads: Bool = false) -> [(String, [String: any Sendable])] {
        var calls: [(String, [String: any Sendable])] = [
            // New-document scripts run only while the Page domain is on, and bindings reach worlds
            // made later only while the Runtime domain is on.
            ("Page.enable", [:]),
            ("Runtime.enable", [:]),
            ("Runtime.addBinding", ["name": bindingName]),
            ("Page.addScriptToEvaluateOnNewDocument", ["source": pageScript(handlers: handlers), "runImmediately": true]),
        ]
        if supportsUploads {
            calls.append(("Page.addScriptToEvaluateOnNewDocument", ["source": "globalThis.__cmuxNativePromptUploads = true;", "runImmediately": true]))
        }
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

    public func uninstall() {
        handler = nil
        scripts.removeAll()
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
        guard let seq = message.seq else { return }
        noteReached()
        if let uploadQueryHandler, let body = message.body as? [String: Any],
           body["t"] as? String == "call", let op = body["op"] as? String,
           (op == "cmux.agent.uploads.status" || op == "cmux.agent.uploads.cancel"),
           let callID = body["id"] as? NSNumber {
            let result: [String: Any]?
            if let descriptor, PageHostTrust.isTrusted(request, page: descriptor) {
                result = await uploadQueryHandler(op, context, body["params"] as? [String: Any] ?? [:])
            } else { result = ["ok": false, "error": ["code": "page.untrusted", "userMessage": "The page is not trusted", "retryable": false]] }
            guard self.handler != nil else { return }
            let reply: [String: Any]
            if result?["ok"] as? Bool == true { reply = ["t": "ok", "id": callID, "value": result?["value"] ?? NSNull()] }
            else {
                let error = result?["error"] as? [String: Any] ?? [:]
                var value: [String: Any] = ["t": "err", "id": callID, "code": error["code"] ?? "upload_failed", "message": error["userMessage"] ?? "The upload could not be completed", "retryable": error["retryable"] ?? false]
                if let details = error["details"] { value["details"] = details }
                if let origin = error["origin"] { value["origin"] = origin }
                reply = value
            }
            let expression = ChromiumPageHostWire.resolveExpression(seq: seq, reply: reply)
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
            answered += 1
            return
        }
        if let uploadHandler, let body = message.body as? [String: Any],
           body["t"] as? String == "call", body["op"] as? String == "cmux.agent.uploads.begin",
           let callID = body["id"] as? NSNumber {
            let result: [String: Any]?
            if let descriptor, PageHostTrust.isTrusted(request, page: descriptor) {
                let params = body["params"] as? [String: Any] ?? [:]
                let reader = ChromiumUploadBlobReader(page: page, context: context, token: params["token"] as? String ?? "")
                let chunks = AsyncThrowingStream<Data, any Error>(unfolding: { try await reader.next() })
                result = await uploadHandler(page, context, params, chunks)
                await reader.close()
            } else {
                result = ["ok": false, "error": ["code": "page.untrusted", "userMessage": "The page is not trusted", "retryable": false]]
            }
            guard self.handler != nil else { return }
            let reply: [String: Any]
            if result?["ok"] as? Bool == true {
                reply = ["t": "ok", "id": callID, "value": result?["value"] ?? NSNull()]
            } else {
                let error = result?["error"] as? [String: Any] ?? [:]
                var value: [String: Any] = ["t": "err", "id": callID, "code": error["code"] ?? "upload_failed",
                         "message": error["userMessage"] ?? "The upload could not be completed",
                         "retryable": error["retryable"] ?? false]
                if let details = error["details"] { value["details"] = details }
                if let origin = error["origin"] { value["origin"] = origin }
                reply = value
            }
            let expression = ChromiumPageHostWire.resolveExpression(seq: seq, reply: reply)
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
            answered += 1
            return
        }
        guard let handler else { return }
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
    /// binding exists wait in the page and go out once it appears.
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
                  pending.set(seq, resolve);
                  send(JSON.stringify({ name, seq, body }));
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
