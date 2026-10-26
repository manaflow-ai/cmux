public import Foundation
import os

/// ``PageHostBridge`` for a Chromium page. Two transports, one page API
/// (`window.webkit.messageHandlers.cmuxPage.postMessage(envelope)` resolving to the reply), so the
/// page does not know which engine or fork shows it:
///
/// - Renderer paths (``PageChromiumPage/usesRendererPaths``), as Chrome's WebUI: the host script and
///   every page's shared document scripts are in every renderer once, at document start
///   (``rendererScripts(handlers:documentScripts:world:channel:)``), and return outside `cmux-page:`
///   main frames. The CEF runtime hands a page channel post only to the tab whose main frame sent
///   it; the post carries the sending document's URL, read in the channel's isolated world
///   (``ChromiumPageHostWire/ChannelPost``). Replies and pushes go through
///   ``PageChromiumPage/evaluate(_:)``. The page opens no DevTools session, so Chromium may share
///   its renderer. Chrome's `WebUIImpl::Send` (content/browser/webui/web_ui_impl.cc) reads the URL
///   in the browser process; the fork's page message does not carry it yet, so the URL here has
///   the trust of the DevTools path's sender check (the document's own `location.href`).
/// - DevTools, before them: `Runtime.addBinding` puts `__cmuxPageHost(string)` in the page's main
///   world and ``setupCalls(handlers:documentScripts:)`` installs the API over it; a call arrives as
///   `Runtime.bindingCalled` with its execution context, which the bridge asks for `location.href`
///   and `window === window.top`, and the reply goes back into that context only.
///
/// Trust: the payload says nothing about its sender. With a ``PageDescriptor`` the bridge refuses a
/// message unless ``PageHostTrust`` passes the sender's frame for it, on either transport; a refused
/// call gets a failure reply, so its promise settles. A reply names the document that asked, so it
/// settles nothing in a document that replaced it. ``evaluate(_:)`` runs scripts in order; the ones
/// queued together go in one evaluation.
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
    /// The DOM event the channel world sends back a post with when the page channel is missing.
    nonisolated public static let unavailableEventName = "cmux-page-host-unavailable"
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
    /// The page's own per-view document scripts on renderer paths (its theme and `data-*`
    /// attributes), run at each commit (``rebind()``): the fork has no per-browser document-start
    /// script yet, and the renderer-wide ones cannot carry one view's values.
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
    /// (its renderer has the host script and the shared document scripts) and `documentScripts` run
    /// at each commit; before them, the DevTools calls of ``setupCalls(handlers:documentScripts:)``.
    ///
    /// - Parameter documentScripts: The page's own document-start scripts, in order; on renderer
    ///   paths only the ones the renderer does not have (``PageChromiumDocumentScripts/perView``).
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
    /// main frame on renderer paths (where the message's document id picks the document).
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
        startAnswer(message, from: .context(call.contextID))
        return true
    }

    /// Handles one post of the page channel (renderer paths), which only this page's main frame
    /// can deliver (the CEF runtime routes it by browser and drops child frames). The sender's URL
    /// is the channel world's, never one the page's text names.
    ///
    /// - Parameter envelope: The channel world's post (``ChromiumPageHostWire/ChannelPost``).
    public func receive(hostMessage envelope: String) {
        guard envelope.utf8.count <= Self.maximumEnvelopeBytes, let post = ChromiumPageHostWire.ChannelPost(envelope: envelope) else {
            logger.error("page host post refused")
            return
        }
        guard let message = parse(post.message) else { return }
        startAnswer(message, from: .mainFrame(PageHostMessage(frameURL: post.url, isMainFrame: true, body: message.body)))
    }

    /// Where a message came from: a DevTools execution context, whose sender is read from it, or the
    /// page's main frame on renderer paths, whose sender the channel world read.
    private enum Origin {
        case context(Int)
        case mainFrame(PageHostMessage)
    }

    private func startAnswer(_ message: ChromiumPageHostWire.Message, from origin: Origin) {
        // task-owner: one message; its reply goes back to the frame that sent it
        Task { [weak self] in await self?.answer(message, from: origin) }
    }

    private func answer(_ message: ChromiumPageHostWire.Message, from origin: Origin) async {
        switch origin {
        case .context(let context): await answerFromContext(message, context: context)
        case .mainFrame(let request): await answer(message, request: request, to: .mainFrame)
        }
    }

    /// Longest page channel post: a message of ``maximumPayloadBytes`` JSON-escaped, and its URL.
    nonisolated public static let maximumEnvelopeBytes = 2 * maximumPayloadBytes + 64 * 1024

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
        if let descriptor, !PageHostTrust.isTrusted(request, page: descriptor) {
            logger.error("page \(descriptor.id, privacy: .public) host message from another frame refused")
            // A refused call still settles, in the frame that asked (the document id picks it).
            if message.name == PageHostTrust.handlerName, let seq = message.seq {
                await reply(Self.refusedReply, seq: seq, document: message.document, to: target)
            }
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
        let answer = await handler(request)
        guard self.handler != nil else { return }
        await reply(answer, seq: seq, document: message.document, to: target)
        answered += 1
    }

    /// The failure envelope a call from a frame that is not the page's own gets.
    static let refusedReply: [String: Any] = ["ok": false, "error": ["code": "native.untrusted_frame", "userMessage": "Refused"]]

    private func reply(_ value: Any?, seq: Int, document: String?, to target: ReplyTarget) async {
        guard let page else { return }
        let expression = ChromiumPageHostWire.resolveExpression(seq: seq, reply: value, document: document)
        switch target {
        case .context(let context):
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
        case .mainFrame:
            _ = try? await page.evaluate(expression)
        }
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
