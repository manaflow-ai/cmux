public import Foundation
import os

/// ``PageHostBridge`` for a Chromium page. Two transports, one page API
/// (`window.webkit.messageHandlers.cmuxPage.postMessage(envelope)` resolving to the reply), so the
/// page does not know which engine or fork shows it:
///
/// - Renderer paths (fork API 29, ``PageChromiumPage/usesRendererPaths``), as Chrome's WebUI: the
///   host script is in every renderer once (``rendererScripts(handlers:world:channel:)``) and
///   returns outside `cmux-page:` documents; posts come on the page channel with their sender read
///   from the frame that delivered them (``PageChromiumSender``); replies and pushes go through
///   ``PageChromiumPage/evaluate(_:)``. The page opens no DevTools session, so Chromium may share its
///   renderer (content/browser/webui/web_ui_impl.cc takes `chrome.send` the same way).
/// - DevTools, before them: `Runtime.addBinding` puts `__cmuxPageHost(string)` in the page's main
///   world and ``setupCalls(handlers:documentScripts:)`` installs the API over it; a call arrives as
///   `Runtime.bindingCalled` with its execution context, which the bridge asks for `location.href`
///   and `window === window.top`, and the reply goes back into that context only.
///
/// Trust: the payload says nothing about its sender. With a ``PageDescriptor`` the bridge drops a
/// message unless ``PageHostTrust`` passes the sender's frame for it, on either transport.
/// ``evaluate(_:)`` runs scripts in order; the ones queued together go in one evaluation.
@MainActor
public final class ChromiumPageHostBridge: PageHostBridge {
    public let engine = PageHostEngine.cef
    /// The binding the page script calls (DevTools path).
    nonisolated public static let bindingName = "__cmuxPageHost"
    /// The page function a reply calls.
    nonisolated public static let resolveName = "__cmuxPageHostResolve"
    /// The page function that adds handlers to a renderer-path document (``rebind()``).
    nonisolated public static let addHandlersName = "__cmuxPageHostAddHandlers"
    /// The DOM event the page world hands a post to the channel world with (renderer paths).
    nonisolated public static let postEventName = "cmux-page-host-post"
    /// Longest message accepted (page calls are small; large data goes through replies and pushes).
    nonisolated public static let maximumPayloadBytes = 4 << 20

    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page-host.chromium")
    private weak var page: (any PageChromiumPage)?
    /// The page whose own documents may talk to the host; nil checks only the main frame.
    private let descriptor: PageDescriptor?
    private let rendererPaths: Bool
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
    /// The page's own document scripts on renderer paths, run at each commit (``rebind()``).
    private var documentScripts: [String] = []
    /// Number of messages answered (tests wait on it).
    public private(set) var answered = 0

    /// - Parameters:
    ///   - page: The Chromium page.
    ///   - descriptor: The page it shows: a message from a frame that is not one of its own
    ///     documents is dropped. Nil checks only that the main frame sent it.
    ///   - fireAndForget: Extra `window.webkit.messageHandlers` names whose messages need no reply.
    public init(page: any PageChromiumPage, descriptor: PageDescriptor? = nil, fireAndForget: [String] = []) {
        self.page = page
        self.descriptor = descriptor
        self.fireAndForget = fireAndForget
        rendererPaths = page.usesRendererPaths
    }

    /// Sets the page up before its first document loads. On renderer paths nothing goes to the page
    /// (its renderer has the host script) and `documentScripts` run at each commit; before them, the
    /// DevTools calls of ``setupCalls(handlers:documentScripts:)``.
    ///
    /// - Parameter documentScripts: The page's own document-start scripts, in order.
    /// - Throws: When a DevTools call fails or the page is gone.
    public func setUp(documentScripts: [String]) async throws(ChromiumPageHostBridgeError) {
        guard let page else { throw .pageGone }
        guard !rendererPaths else {
            self.documentScripts = documentScripts
            return
        }
        for (method, params) in Self.setupCalls(handlers: fireAndForget, documentScripts: documentScripts) {
            do {
                _ = try await page.devTools(method, params: params)
            } catch {
                throw .setupFailed(method, "\(error)")
            }
        }
    }

    /// The DevTools calls that set the page up, in order: run them before the first document loads
    /// (``setUp(documentScripts:)``), then again for every committed document (``rebind()``).
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

    /// A new document committed. On renderer paths its handlers and the page's document scripts go
    /// first in the script queue; on DevTools the binding goes in again (a no-op where it is there).
    public func rebind() {
        guard rendererPaths else {
            guard let page else { return }
            // task-owner: one idempotent call on a page that may already be gone
            Task { _ = try? await page.devTools("Runtime.addBinding", params: ["name": Self.bindingName]) }
            return
        }
        let names = fireAndForget.map(ChromiumPageHostWire.jsonString).joined(separator: ", ")
        enqueueFirst(["globalThis.\(Self.addHandlersName)?.([\(names)]);"] + documentScripts)
    }

    public func evaluate(_ script: String) {
        scripts.append(script)
        startDrain()
    }

    private func enqueueFirst(_ first: [String]) {
        scripts.insert(contentsOf: first, at: 0)
        startDrain()
    }

    private func startDrain() {
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
            let expression = Self.batch(takeBatch())
            if rendererPaths {
                _ = try? await page.evaluate(expression)
            } else {
                _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "silent": true])
            }
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

    /// The most script bytes sent in one evaluation.
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

    /// Where a reply goes: the DevTools execution context that sent the message, or the page's
    /// main frame on renderer paths.
    private enum ReplyTarget {
        case context(Int)
        case mainFrame
    }

    /// Handles one raw DevTools message of the page: true when it was this bridge's binding call.
    @discardableResult
    public func receive(devToolsMessage json: String) -> Bool {
        guard json.contains(Self.bindingName), let call = ChromiumPageHostWire.BindingCall(event: json),
              call.name == Self.bindingName else { return false }
        guard let message = parse(call.payload) else { return true }
        // task-owner: one message; its reply goes back to the context that sent it
        Task { [weak self] in await self?.answerFromContext(message, context: call.contextID) }
        return true
    }

    /// Handles one post of the page channel (renderer paths). `sender` is the frame that delivered
    /// it, as the browser knows it: whatever the payload names, the message is that frame's.
    ///
    /// - Parameters:
    ///   - payload: The post, untrusted.
    ///   - sender: The delivering frame.
    public func receive(hostMessage payload: String, from sender: PageChromiumSender) {
        guard let message = parse(payload) else { return }
        let request = PageHostMessage(frameURL: sender.url, isMainFrame: sender.isMainFrame, body: message.body)
        // task-owner: one message; its reply goes back to the page's main frame
        Task { [weak self] in await self?.answer(message, request: request, to: .mainFrame) }
    }

    private func parse(_ payload: String) -> ChromiumPageHostWire.Message? {
        guard payload.utf8.count <= Self.maximumPayloadBytes, let message = ChromiumPageHostWire.Message(payload: payload) else {
            logger.error("page host payload refused")
            return nil
        }
        return message
    }

    private func answerFromContext(_ message: ChromiumPageHostWire.Message, context: Int) async {
        guard let page else { return }
        let senderJSON = try? await page.devTools("Runtime.evaluate", params: [
            "expression": "[location.href, window === window.top]",
            "contextId": context, "returnByValue": true, "silent": true,
        ])
        let sender = senderJSON.flatMap(ChromiumPageHostWire.Sender.init(evaluation:))
        let request = PageHostMessage(frameURL: sender?.url, isMainFrame: sender?.isTop ?? false, body: message.body)
        await answer(message, request: request, to: .context(context))
    }

    private func answer(_ message: ChromiumPageHostWire.Message, request: PageHostMessage, to target: ReplyTarget) async {
        guard let page else { return }
        if let descriptor, !PageHostTrust.isTrusted(request, page: descriptor) {
            logger.error("page \(descriptor.id, privacy: .public) host message from another frame refused")
            return
        }
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
        switch target {
        case .context(let context):
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
        case .mainFrame:
            _ = try? await page.evaluate(expression)
        }
        answered += 1
    }

    private func noteReached() {
        guard !reachedHost else { return }
        reachedHost = true
        onFirstMessage?()
    }
}

/// Why ``ChromiumPageHostBridge/setUp(documentScripts:)`` failed.
public nonisolated enum ChromiumPageHostBridgeError: Error, Equatable {
    /// The page closed first.
    case pageGone
    /// A DevTools setup call failed: the method and the error.
    case setupFailed(String, String)
}
