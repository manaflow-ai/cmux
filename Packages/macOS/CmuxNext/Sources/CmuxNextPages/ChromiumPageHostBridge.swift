import CmuxNextCompat
public import Foundation
import CmuxNextWakeups
import os

/// ``PageHostBridge`` for a Chromium page, through the DevTools protocol only (no render-process
/// code, so neither the Chromium fork nor the shim changes).
///
/// - `Runtime.addBinding` puts `__cmuxPageHost(string)` in the page's main world; a call arrives
///   as a `Runtime.bindingCalled` event with the caller's execution context.
/// - A script for every new document (``pageScript(handlers:)``) installs the WebKit-shaped API
///   on top of it (`window.webkit.messageHandlers.cmuxPage.postMessage(envelope)` resolving to the
///   reply), so the page does not know which engine shows it.
/// - Trust: the payload says nothing about its sender. The bridge asks the sender's own context
///   for `location.href` and `window === window.top` (both unforgeable), and ``PageHostTrust``
///   checks them as for WebKit. It asks once per context (``sender(of:)``), not once per message:
///   a context is one document of one frame for its whole life, so neither answer can change
///   enough to change the verdict (a same-document navigation keeps the origin, which is all the
///   trust rule reads). A failed ask is asked again and its reason logged (cmux#48605).
/// - Replies go back into the sender's context only (`__cmuxPageHostResolve(seq, reply)`).
/// - ``evaluate(_:)`` runs scripts in order; the ones queued together go in one `Runtime.evaluate`.
/// - The Runtime domain is on only while a navigation starts: on, a new document's main world
///   gets the binding when it is made (before any page script runs); off, no binding reaches a new
///   world, but V8 also stops reporting every context and console call to the session, which made
///   the chat page's modules evaluate in 116 ms instead of 44 (headless Chromium, cold). So
///   ``navigate(_:)`` turns it on (with the binding again: turning it off drops the session's
///   bindings) before each navigation the app starts, and ``documentCommitted()`` turns it off once
///   the main frame commits, before the document's scripts run. Calls, replies and
///   `Runtime.evaluate` in a context id all work with it off.
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
    /// Messages dropped because their sender context never answered the sender check (tests wait on it).
    public private(set) var unknownSenders = 0
    /// The host's pushes into the page since it was made: scripts, `Runtime.evaluate` batches and their bytes, each
    /// batch JSON-parsed by Chromium on the main thread (`debug.page` state's `pushes`; the many-chats bench reads it).
    public private(set) var pushes = (scripts: 0, batches: 0, bytes: 0)
    /// Binding calls waiting for their parse off the main actor, in arrival order.
    private var inbox: AsyncStream<String>.Continuation?
    private var reading: Task<Void, Never>?
    /// Whether the Runtime domain is on in the page's DevTools session, as the calls sent so far
    /// leave it (``setUp(documentScripts:)`` turns it on, ``documentCommitted()`` off).
    public private(set) var runtimeEnabled = false
    /// The page's renderer ended (``rendererEnded()``) and no document has committed since: a
    /// DevTools call would wait for the next renderer, which only the navigation brings.
    private var rendererGone = false
    /// The Runtime switches and the navigations that wait for them, in order; nil when none runs.
    private var runtimeSwitch: Task<Void, Never>?
    private var runtimeSwitches = 0
    /// The sender each execution context answered (``sender(of:)``), until its document goes.
    private var senders: [Int: ChromiumPageHostWire.Sender] = [:]
    /// The sender asks out now, one per context: the messages of a context that arrive while its
    /// ask is out wait for that ask instead of each sending its own.
    private var senderAsks: [Int: Task<ChromiumPageHostWire.Sender?, Never>] = [:]
    /// Which documents the kept senders are of: a commit or a renderer's end starts a new one, and an
    /// ask that answers after that keeps nothing (a new renderer may number its contexts again).
    private var senderEpoch = 0

    /// - Parameters:
    ///   - page: The Chromium page.
    ///   - fireAndForget: Extra `window.webkit.messageHandlers` names whose messages need no reply.
    public init(page: any PageChromiumPage, fireAndForget: [String] = []) {
        self.page = page
        self.fireAndForget = fireAndForget
    }

    /// The DevTools calls that set the page up, in order: ``setUp(documentScripts:)`` runs them
    /// before the first document loads. The Runtime domain stays on until that document commits
    /// (``documentCommitted()``).
    public static func setupCalls(handlers: [String], documentScripts: [String]) -> [(String, [String: any Sendable])] {
        var calls: [(String, [String: any Sendable])] = [
            // New-document scripts run only while the Page domain is on, and bindings reach worlds
            // made later only while the Runtime domain is on.
            ("Page.enable", [:]),
            ("Runtime.enable", [:]),
            bindingCall,
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

    /// Runs ``setupCalls(handlers:documentScripts:)`` (with this bridge's ``fireAndForget``
    /// handlers) on the page, in order, before its first load: the Runtime domain is on after it.
    public func setUp(documentScripts: [String]) async throws {
        try await startSetUp(documentScripts: documentScripts)()
    }

    /// ``setUp(documentScripts:)`` in two steps: sends every setup call now, in order, in this turn,
    /// and returns what awaits their answers, so they come in about one round trip instead of one
    /// each (one at a time, the chat page's setup took about 50 ms). Other calls sent in the same
    /// turn go after them. Awaiting it throws the first failed call's error, as one at a time did.
    public func startSetUp(documentScripts: [String]) throws -> @MainActor () async throws -> Void {
        guard let page else { throw PageError.unavailable("the Chromium page is gone") }
        // Sent in order now (the page keeps its call order), not raced as child tasks.
        let answers = Self.setupCalls(handlers: fireAndForget, documentScripts: documentScripts).map { call in
            page.startDevTools(call.0, params: call.1)
        }
        return {
            for answer in answers { _ = try await answer() }
            self.runtimeEnabled = true
        }
    }

    nonisolated static let bindingCall: (String, [String: any Sendable]) = ("Runtime.addBinding", ["name": bindingName])

    /// The calls that turn the Runtime domain on for a navigation: on, then the binding again
    /// (`Runtime.disable` dropped the session's bindings; without it the new document never gets
    /// one, measured).
    nonisolated static let enableCalls: [(String, [String: any Sendable])] = [("Runtime.enable", [:]), bindingCall]

    /// The calls for a committed main-frame document: the Runtime domain off (when it is on), then
    /// the binding again. The binding call puts the binding in the document's main world whatever
    /// the domain's state: a navigation the page started itself (``navigate(_:)`` did not turn the
    /// domain on for it) gets it this way, a few milliseconds after its start, and the page script
    /// keeps the page's messages until then. Where the binding is there already, it is a no-op.
    nonisolated static func commitCalls(runtimeEnabled: Bool) -> [(String, [String: any Sendable])] {
        var calls: [(String, [String: any Sendable])] = []
        if runtimeEnabled { calls.append(("Runtime.disable", [:])) }
        calls.append(bindingCall)
        return calls
    }

    /// Starts a navigation the app asks for (`navigate` loads or reloads the page) once the Runtime
    /// domain is on, so the new document's main world gets the binding when it is made. With the
    /// domain off, `navigate` runs after the page answered the calls that turn it on (measured: a
    /// domain turned on when Chromium reports the navigation started is too late, and slowed a
    /// reload from 40 to 108 ms); navigations run in the order asked. With it on and nothing in
    /// flight, or after the renderer ended (``rendererEnded()``), `navigate` runs at once.
    ///
    /// Not for app health's restart of a renderer that stopped answering (``PageChromiumPage/restartRenderer()``):
    /// that must not wait on the renderer, and its document gets the binding with its commit.
    ///
    /// - Parameter navigate: Loads or reloads the page.
    public func navigate(_ navigate: @escaping () -> Void) {
        guard !rendererGone else { return navigate() }
        if !runtimeEnabled {
            runtimeEnabled = true
            switchRuntime(Self.enableCalls, then: navigate)
        } else if runtimeSwitch != nil {
            switchRuntime([], then: navigate)
        } else {
            navigate()
        }
    }

    /// The main frame committed a new document of the page: the Runtime domain goes off before the
    /// document's scripts run (``commitCalls(runtimeEnabled:)``). When requested, the readiness
    /// script is asked to resend its current state after the binding is re-added; this closes the
    /// Runtime-disable event gap without keeping the expensive Runtime domain enabled.
    public func documentCommitted(resendInputReadiness: Bool = false) {
        rendererGone = false
        forgetSenders()
        let calls = Self.commitCalls(runtimeEnabled: runtimeEnabled)
        runtimeEnabled = false
        switchRuntime(calls) { [weak self] in
            guard resendInputReadiness else { return }
            self?.evaluate("globalThis.__cmuxInputReadyResend?.();")
        }
    }

    /// The page's renderer ended: until a document commits again, ``navigate(_:)`` does not wait on
    /// DevTools calls (they would be answered only by the renderer that navigation brings), and
    /// the binding comes with the commit.
    public func rendererEnded() {
        rendererGone = true
        forgetSenders()
    }

    /// DevTools events after which a context number may name another document's context.
    nonisolated static func endsContexts(_ method: String?) -> Bool {
        method == "Page.frameNavigated" || method == "Runtime.executionContextsCleared" || method == "Runtime.executionContextDestroyed"
    }

    /// A document of the page was replaced or ended, whether or not it is one the page keeps (an
    /// `about:` commit, one the navigation policy sends back): no kept sender outlives it.
    public func documentReplaced() {
        forgetSenders()
    }

    /// The page's contexts went with their document or renderer: their senders are asked anew.
    private func forgetSenders() {
        senderEpoch += 1
        senders.removeAll()
        senderAsks.removeAll()
    }

    /// Sends `calls` after the switches before them, then runs `then`.
    private func switchRuntime(_ calls: [(String, [String: any Sendable])], then: (() -> Void)? = nil) {
        let previous = runtimeSwitch
        let page = page
        runtimeSwitches += 1
        let number = runtimeSwitches
        // task-owner: the bridge's Runtime switch FIFO; each ends after its calls (each bounded by
        // the DevTools call deadline) and clears itself when it is the last
        runtimeSwitch = Task { [weak self, weak page] in
            await previous?.value
            for (method, params) in calls {
                guard let page else { break }
                _ = try? await page.devTools(method, params: params)
            }
            guard let self else { return }
            if self.runtimeSwitches == number { self.runtimeSwitch = nil }
            then?()
        }
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
            let expression = Self.batch(batch)
            pushes.scripts += batch.count
            pushes.batches += 1
            pushes.bytes += expression.utf8.count
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "silent": true])
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
        // A frame's new document, or contexts cleared (a cross-process swap), in the same ordered stream
        // as the binding calls: no call after it is answered with a sender kept from before it, whatever
        // number its context reuses (a new renderer numbers its contexts again).
        if Self.endsContexts(head.method) { documentReplaced() }
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
        guard let sender = await sender(of: context) else {
            // Answered as if from a subframe, the main frame's message was refused as untrusted and a
            // fire-and-forget one (input readiness) was lost without a word, so typing stayed held for
            // good. Dropped here instead; the page re-sends its readiness, and a call settles with null.
            unknownSenders += 1
            logger.error("page host message \(message.name, privacy: .public) dropped: its sender context \(context) did not answer the sender check")
            guard message.name == PageHostTrust.handlerName, handler != nil, let seq = message.seq else { return }
            let expression = ChromiumPageHostWire.resolveExpression(seq: seq, reply: nil)
            _ = try? await page.devTools("Runtime.evaluate", params: ["expression": expression, "contextId": context, "silent": true])
            return
        }
        let request = PageHostMessage(frameURL: sender.url, isMainFrame: sender.isTop, body: message.body, json: message.json)
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

    /// The sender of the messages of execution context `context`: kept from its first answer, else
    /// asked of the context (one ask at a time per context, ``askSender(of:)``). Before, every message
    /// cost a DevTools round trip in the browser's call order, behind the page's queued scripts
    /// (cmux#48605: a chat page's open makes dozens of calls, and under load the handshake and the
    /// first-paint report waited behind them until the loading state gave up). Nil when no try answered.
    func sender(of context: Int) async -> ChromiumPageHostWire.Sender? {
        if let known = senders[context] { return known }
        if let out = senderAsks[context] { return await out.value }
        let epoch = senderEpoch
        // task-owner: one context's sender ask; bounded by senderTries DevTools calls, each bounded
        // by the DevTools call deadline, and dropped with the context's document (forgetSenders)
        let ask = Task { [weak self] in await self?.askSender(of: context) }
        senderAsks[context] = ask
        let sender = await ask.value
        guard epoch == senderEpoch else { return sender }
        senderAsks[context] = nil
        if let sender { senders[context] = sender }
        return sender
    }

    /// The sender check of `context`, ``senderTries`` times at most (20 then 80 ms apart): under full CPU load
    /// (or right after a navigation) one `Runtime.evaluate` can time out or fail, and the message is the
    /// page's main frame more often than not. Nil when every try failed; that failure is not kept, so the
    /// context's next message asks again.
    private func askSender(of context: Int) async -> ChromiumPageHostWire.Sender? {
        var backoff = Backoff(initial: .milliseconds(20), maximum: .milliseconds(80), multiplier: 4, jitter: 0)
        var failure = "the page is gone"
        for attempt in 0..<Self.senderTries {
            if attempt > 0 {
                // concurrency-allow: Backoff.wait is an async sleep after a failed sender check, not a blocking wait.
                do { try await backoff.wait(owner: "page-host.sender-check") } catch { return nil }
            }
            guard let page else { break }
            do {
                let json = try await page.devTools("Runtime.evaluate", params: [
                    "expression": ChromiumPageHostWire.senderExpression,
                    "contextId": context, "returnByValue": true, "silent": true,
                ])
                if let sender = ChromiumPageHostWire.Sender(evaluation: json) { return sender }
                // Not the answer itself: it can name the page's address.
                failure = "an unreadable answer (\(json.utf8.count) bytes)"
            } catch {
                failure = String(describing: error)
            }
        }
        logger.error("page host sender check of context \(context) failed \(Self.senderTries) times: \(failure, privacy: .public)")
        return nil
    }

    /// How many times the sender check is tried before its message is dropped.
    nonisolated static let senderTries = 3

    private func noteReached() {
        guard !reachedHost else { return }
        reachedHost = true
        onFirstMessage?()
    }
}
