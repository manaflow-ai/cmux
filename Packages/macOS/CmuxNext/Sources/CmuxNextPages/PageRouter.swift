package import CmuxNextHibernation
public import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation
public import Foundation

/// The host half of a page's bridge, engine neutral: it reads pane-protocol envelopes
/// (plans/cmux-next/pane-protocol.md "Wire") from the page, checks them against the page's
/// ``PageDescriptor``, routes calls and subscriptions to providers, and pushes events and host
/// calls back through `send`. The engine bridge (``PageHostBridge``) only carries bytes.
///
/// Rules every page gets here, so no provider repeats them:
/// - only ops and streams the descriptor admits reach a provider; the rest is `unknown_op`;
/// - params must be an object; an `origin` or a confirmation the page sends is refused (the host
///   stamps `page`; only a native confirmation sheet makes a call the user's);
/// - events of one subscription are numbered from 1; an unsubscribe or ``close()`` cancels.
@MainActor
public final class PageRouter {
    public private(set) var descriptor: PageDescriptor
    private(set) var routes: [PageRoute]
    /// Runs one envelope in the page (`window.__cmuxPageReceive(<json>)`).
    public var send: ((JSONValue) -> Void)?
    /// Script pipeline entry that reports envelopes dropped by a page reset.
    public var sendWithDrop: ((JSONValue, @escaping @MainActor () -> Void) -> Void)?
    /// Runs at every ``close()`` (and so at ``reset()`` and rebind): the host drops envelopes it
    /// has not delivered yet, which belong to the subscriptions that just ended.
    public var didClose: (() -> Void)?
    // Not private: PageRouter+Hold.swift reads the streams and writes `sequences` and `held`.
    private(set) var subscriptions: [UInt64: PageSubscription] = [:]
    private var activeStreams: Set<UInt64> = []
    private(set) var streamProviders: [UInt64: (name: String, provider: any PageProvider)] = [:]
    var sequences: [UInt64: UInt64] = [:]
    private var nextSubscription: UInt64 = 1
    private var nextCall: UInt64 = 1
    private var pendingCalls: [UInt64: OnceContinuation<JSONValue, any Error>] = [:]
    /// Page calls still running, by page call id: cancelled by the page's `cancel` envelope, by
    /// navigation (`reset`) and by tab close (`close`) (app-op-routing.md "Op cancel").
    private var inFlight: [UInt64: PageCallInFlight] = [:]
    private var closed = false
    /// The document the router serves: one more at every ``close()`` (a reload, a crash, a
    /// navigation, a rebind). A call keeps the one it arrived in, so state it sets for its document
    /// (``PageNativeOp/keepAlive``) never lands on the next one.
    private var document: UInt64 = 0
    /// Built-in streams every page gets (``PageNativeOp/pageCommand``, ``PageNativeOp/pageConnection``):
    /// subscription id to stream name.
    private(set) var builtIn: [UInt64: String] = [:]
    /// The owner link state the connection stream reports.
    public private(set) var connected = true
    /// The page's lifecycle: thaws before a command or host call, hears an `.ordered` stream fill.
    public weak var lifecycle: (any PageDeliveryLifecycle)?
    /// Events kept while delivery is held, per subscription, by the stream's ``PageFrozenDelivery``.
    var held = PageDeliveryHold()
    /// Why ``held`` holds (PageRouter+Hold.swift): it releases once no reason is left.
    var holdReasons: Set<PageDeliveryHoldReason> = []
    /// Whether the providers were told the page froze (``pageWillFreeze()``) and not yet that it thawed.
    public internal(set) var providersFrozen = false
    /// Sends what the host's script pipeline keeps for the next frame now: a built-in command or a
    /// host call was just sent and must not wait a frame (``PageWebView`` sets it).
    var deliverNow: (@MainActor () -> Void)?
    #if DEBUG || CMUX_BENCH_HOOKS
    /// Whether the page's view is hidden, as its ``PageWebView`` tells the engine (`debug.webui`).
    public internal(set) var debugPageHidden = false
    /// Events delivered while ``debugPageHidden``: one integer add per delivery (`debug.webui`).
    public internal(set) var debugDeliveriesWhileHidden = 0
    /// The page's oracle reading may have changed (``oracleStateChangedOp``): the page
    /// host's feed (``WebUIHost/oracleChanges``) wakes `debug.oracle.wait_for` on the `webviews` facet.
    public var oracleStateChanged: (@MainActor () -> Void)?
    #endif

    public init(descriptor: PageDescriptor, routes: [PageRoute]) {
        self.descriptor = descriptor
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// Rebinds a pooled router to a new document and ends every operation owned by the old page.
    func rebind(descriptor: PageDescriptor, routes: [PageRoute]) {
        reset()
        renewHold()
        // The freeze is the engine's: the old providers hear its end, the new ones its start.
        let frozen = providersFrozen
        pageDidThaw()
        self.descriptor = descriptor
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
        if frozen { pageWillFreeze() }
    }

    // MARK: Page to host

    /// Handles one envelope the page posted and returns the reply envelope (or `null` for
    /// messages that need none: `unsub`, and replies to host calls).
    public func handle(_ message: JSONValue) async -> JSONValue {
        guard let type = message["t"]?.stringValue else { return Self.error(id: 0, .invalidParams("missing t")) }
        let id = message["id"]?.doubleValue.map { UInt64(max(0, $0)) } ?? 0
        switch type {
        case "call":
            guard let op = message["op"]?.stringValue else { return Self.error(id: id, .invalidParams("missing op")) }
            do {
                var opid: String?
                if let raw = message["opid"] {
                    guard let text = raw.stringValue, PageCallContext.isValidOpid(text) else {
                        return Self.error(id: id, PageError(code: "cmux.protocol.bad_message", message: "opid must be 1-128 characters of [A-Za-z0-9._:-]"))
                    }
                    opid = text
                }
                let params = message["params"] ?? .object([:])
                let document = document
                let value = try await cancellable(id: id, op: op) { [self] in
                    try await call(op, params: params, opid: opid, document: document)
                }
                return ["t": "ok", "id": .number(Double(id)), "value": value]
            } catch let error as PageError {
                return Self.error(id: id, error)
            } catch {
                return Self.error(id: id, PageError(code: "cmux.page.failed", message: String(describing: error)))
            }
        case "sub":
            guard let stream = message["stream"]?.stringValue else { return Self.error(id: id, .invalidParams("missing stream")) }
            do {
                let sub = try await subscribe(stream, filter: message["filter"] ?? .object([:]))
                return ["t": "ok", "id": .number(Double(id)), "value": ["sub": .number(Double(sub))]]
            } catch let error as PageError {
                return Self.error(id: id, error)
            } catch {
                return Self.error(id: id, PageError(code: "cmux.page.failed", message: String(describing: error)))
            }
        case "cancel":
            // A cancel of an unknown or finished id is a no-op; it gets no reply.
            inFlight[id]?.cancel()
            return .null
        case "unsub":
            if let sub = message["sub"]?.doubleValue { unsubscribe(UInt64(max(0, sub))) }
            return .null
        case "ok", "err":
            resolve(id: id, message)
            return .null
        default:
            return Self.error(id: id, .invalidParams("unknown message \(type)"))
        }
    }

    /// When a real key or mouse event reached the page's view just now (PageWKWebView, its
    /// `systemUptime`), else nil; nil in tests without a view.
    public var userGestureEvent: (@MainActor () -> TimeInterval?)?

    /// The window's title bar action (DESKTOP-FEEL): a double-click on a title bar the page draws.
    public var titleBarDoubleClick: (@MainActor () -> Void)?

    /// A popup op (`cmux.app.popup.*`, cx-6k6cg) with its params: the page view's WebPopupHost.
    public var popup: (@MainActor (String, [String: Any]) -> JSONValue)?

    /// A right-click menu (`cmux.app.contextMenu.show`) with its params: the page view's native
    /// menu, answered once it closes.
    public var contextMenu: (@MainActor ([String: Any]) async -> JSONValue)?

    /// The page's `cmux.page.keepAlive`, checked: one of its own reasons, on or off (``PageKeepReasons``).
    package var keepAlive: (@MainActor (PageLifecyclePlanner.KeepReason, Bool) -> Void)?

    private func call(_ op: String, params: JSONValue, opid: String?, document: UInt64) async throws -> JSONValue {
        #if DEBUG || CMUX_BENCH_HOOKS
        if op == Self.oracleStateChangedOp {
            guard !closed else { throw PageError.closed }
            oracleStateChanged?()
            return .object([:])
        }
        #endif
        if op == PageNativeOp.keepAlive {
            // Its document ended before the call ran (its task was cancelled, but a cancelled task
            // still runs): the next document's reasons are its own.
            guard !closed, document == self.document, !Task.isCancelled else { throw PageError.closed }
            let request = try PageKeepReasons.pageRequest(params)
            keepAlive?(request.reason, request.on)
            return .object([:])
        }
        if op == PageNativeOp.titleBarDoubleClick {
            guard !closed else { throw PageError.closed }
            titleBarDoubleClick?()
            return .object([:])
        }
        if op == PageNativeOp.popupShow || op == PageNativeOp.popupUpdate || op == PageNativeOp.popupHide {
            guard !closed else { throw PageError.closed }
            guard case .object = params, let fields = params.foundationObject as? [String: Any] else {
                throw PageError.invalidParams("params must be an object")
            }
            return popup?(op, fields) ?? .object(["shown": .bool(false)])
        }
        if op == PageNativeOp.contextMenu {
            guard !closed else { throw PageError.closed }
            guard case .object = params, let fields = params.foundationObject as? [String: Any] else {
                throw PageError.invalidParams("params must be an object")
            }
            return await contextMenu?(fields) ?? .object(["picked": .null])
        }
        let (provider, params) = try admit(op, params: params)
        let gesture = userGestureEvent?() ?? nil
        return try await provider.call(op, params: params, context: PageCallContext(page: descriptor.id, opid: opid,
                                                                                     userGesture: gesture != nil, gestureEvent: gesture))
    }

    /// Runs `work` as page call `id`, answering `cmux.op.cancelled` at once when the call is
    /// cancelled; the work's task is cancelled too, so the owner stops (a relay cancels its op).
    private func cancellable(id: UInt64, op: String, _ work: @escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue {
        let call = PageCallInFlight(op: op)
        inFlight[id] = call
        defer { if inFlight[id] === call { inFlight[id] = nil } }
        return try await withOnceThrowingContinuation { (continuation: OnceContinuation<JSONValue, any Error>) in
            call.start(continuation, work)
        }
    }

    private func subscribe(_ stream: String, filter: JSONValue) async throws -> UInt64 {
        if stream == PageNativeOp.pageCommand || stream == PageNativeOp.pageConnection || stream == PageNativeOp.pagePopup {
            guard !closed else { throw PageError.closed }
            let sub = nextSubscription
            nextSubscription += 1
            builtIn[sub] = stream
            if stream == PageNativeOp.pageConnection {
                // The current state, after the subscribe reply that names `sub` reaches the page.
                let connected = connected
                // task-owner: one event delivery after the reply; ends with the router
                // main-hop-allow: the event must reach the page after the subscribe reply that names sub, which the caller sends when this call returns; the job only orders one delivery behind it
                Task { @MainActor [weak self] in self?.deliver(sub: sub, ["connected": .bool(connected)]) }
            }
            return sub
        }
        let (provider, filter) = try admit(stream, params: filter)
        let sub = nextSubscription
        nextSubscription += 1
        activeStreams.insert(sub)
        streamProviders[sub] = (stream, provider)
        // A provider may send its current state from inside `subscribe` (the icon picker's open
        // session). Those events wait until the reply that names `sub` reaches the page.
        let early = PageEarlyEvents()
        let subscription: PageSubscription
        do {
            subscription = try await provider.subscribe(stream, filter: filter, context: PageCallContext(page: descriptor.id)) { [weak self] data in
                if !provider.eventsAfterSubscribeReply, early.hold(data) { return }
                self?.deliver(sub: sub, data, publicationID: provider.eventDeliveryID)
            }
        } catch {
            activeStreams.remove(sub)
            streamProviders.removeValue(forKey: sub)
            held.remove(sub)
            throw error
        }
        guard !closed else {
            subscription.cancel()
            activeStreams.remove(sub)
            streamProviders.removeValue(forKey: sub)
            held.remove(sub)
            throw PageError.closed
        }
        activeStreams.remove(sub)
        subscriptions[sub] = subscription
        // Events held while `subscribe` ran were kept whole; the stream's policy applies from now.
        reportDropped(held.apply(subscription.frozenDelivery, to: sub), sub: sub)
        // Nothing held: later events go straight to the page. Otherwise they queue behind the held
        // ones until the flush, which runs after the reply.
        guard !early.isHolding || provider.eventsAfterSubscribeReply else {
            if provider.eventsAfterSubscribeReply { return sub }
            _ = early.release()
            return sub
        }
        // task-owner: one flush after the reply; ends with the router
        // main-hop-allow: the held events must reach the page after the subscribe reply that names sub, which the caller sends when this call returns; the job only orders their delivery behind it
        Task { @MainActor [weak self] in
            for data in early.release() { self?.deliver(sub: sub, data, publicationID: provider.eventDeliveryID) }
        }
        return sub
    }

    private func admit(_ op: String, params: JSONValue) throws -> (any PageProvider, JSONValue) {
        guard !closed else { throw PageError.closed }
        guard descriptor.admits(op), let route = routes.first(where: { op.hasPrefix($0.prefix) }) else {
            throw PageError.unknownOp(op)
        }
        guard case .object(let members) = params else { throw PageError.invalidParams("params must be an object") }
        for reserved in ["origin", "confirmed", "confirmation"] where members[reserved] != nil {
            throw PageError.invalidParams("\(reserved) is set by the host")
        }
        return (route.provider, params)
    }

    /// One event of subscription `sub`: to the page now, or into the hold.
    private func deliver(sub: UInt64, _ data: JSONValue, publicationID: UInt64? = nil) {
        guard subscriptions[sub] != nil || builtIn[sub] != nil || activeStreams.contains(sub) else { return }
        guard held.isHeld else { return emit(sub: sub, data, publicationID: publicationID) }
        let kept = held.keep(sub: sub, data, publicationID: publicationID, policy: frozenDelivery(of: sub))
        reportDropped(kept.dropped, sub: sub)
        guard kept.halfFull else { return }
        // The page leaves Frozen (it stays hidden) and takes what was held; the hold goes on, so no
        // `.ordered` stream keeps more than half of its provider's buffer.
        lifecycle?.orderedDeliveryHalfFull()
        emit(held.flush())
    }

    private func unsubscribe(_ sub: UInt64) {
        subscriptions.removeValue(forKey: sub)?.cancel()
        activeStreams.remove(sub)
        streamProviders.removeValue(forKey: sub)
        builtIn.removeValue(forKey: sub)
        sequences.removeValue(forKey: sub)
        // The page ended the stream: what it held is not wanted, so it is not a delivery drop.
        held.remove(sub)
    }

    // MARK: Built-in streams

    /// Sends a dispatcher command to the page's command subscribers, past the hold and after a
    /// thaw (Cmd-F focusSearch on a frozen page). False when the command is not a page command or
    /// no subscriber listens.
    @discardableResult
    public func publishCommand(_ command: String, arguments: [String: JSONValue] = [:]) -> Bool {
        guard descriptor.commands.contains(command) else { return false }
        var data = arguments
        data["command"] = .string(command)
        let subs = builtIn.filter { $0.value == PageNativeOp.pageCommand }.keys.sorted()
        guard !subs.isEmpty else { return false }
        lifecycle?.thawForDelivery()
        for sub in subs { emit(sub: sub, .object(data)) }
        deliverNow?()
        return true
    }

    /// Sends a popup event (`{type, id?}`) to the page's popup subscribers.
    public func publishPopup(_ event: JSONValue) {
        for sub in builtIn.filter({ $0.value == PageNativeOp.pagePopup }).keys.sorted() { deliver(sub: sub, event) }
    }

    /// Records the owner link state and tells the page's connection subscribers when it changes.
    public func publishConnection(_ connected: Bool) {
        guard connected != self.connected else { return }
        self.connected = connected
        for sub in builtIn.filter({ $0.value == PageNativeOp.pageConnection }).keys.sorted() {
            deliver(sub: sub, ["connected": .bool(connected)])
        }
    }

    // MARK: Host to page

    /// Calls an op the page serves (`cmux.page.command`) and waits for its reply. The call goes
    /// past the hold, after a thaw, so a frozen page answers it.
    public func callPage(_ op: String, params: JSONValue) async throws -> JSONValue {
        try await callPage(op, params: params) { _ in }
    }

    /// ``callPage(_:params:)`` that tells `started` the call's id once it is pending, so a caller
    /// whose deadline passed can ``abandonCall(_:)`` it.
    func callPage(_ op: String, params: JSONValue, started: (UInt64) -> Void) async throws -> JSONValue {
        guard !closed, let send else { throw PageError.closed }
        let id = nextCall
        nextCall += 1
        lifecycle?.thawForDelivery()
        return try await withOnceThrowingContinuation { (continuation: OnceContinuation<JSONValue, any Error>) in
            pendingCalls[id] = continuation
            started(id)
            send(["t": "call", "id": .number(Double(id)), "op": .string(op), "params": params])
            deliverNow?()
        }
    }

    /// Fails pending host call `id` with `CancellationError` and forgets it: its caller gave up (a
    /// deadline passed), so a page that never replies keeps no continuation here and a late reply
    /// resolves nothing. A finished or unknown id is a no-op.
    func abandonCall(_ id: UInt64) {
        pendingCalls.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    /// Host calls still waiting for the page's reply.
    var pendingHostCalls: Int { pendingCalls.count }

    private func resolve(id: UInt64, _ message: JSONValue) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        if message["t"]?.stringValue == "ok" {
            continuation.resume(returning: message["value"] ?? .null)
        } else {
            continuation.resume(throwing: PageError(
                code: message["code"]?.stringValue ?? "cmux.page.failed", message: message["message"]?.stringValue ?? ""))
        }
    }

    /// The page went away (tab closed, discarded): cancels every subscription and fails pending
    /// calls, then thaws the providers of a frozen page. Held events never reached the page, so each
    /// reports a drop, as the pipeline's do. The hold itself stays.
    public func close() {
        endDocument()
        // The streams ended above, so the thaw restarts nothing and the freeze and thaw calls a
        // provider gets pair up.
        pageDidThaw()
    }

    /// Reopens for a new document of the same page (a reload, a crash reload, a commit): it starts
    /// with no subscriptions; an ended router (``end()``) stays closed. The providers' freeze state
    /// stays: it follows the engine's (``PageWebView/freezePage()``), not the document's, so the
    /// streams of a frozen page's new document start paused and resync on the thaw. The hold stays
    /// too: a hidden page that reloads is still hidden.
    public func reset() {
        endDocument()
        closed = isEnded
    }

    /// ``end()`` ran: the page closed for good.
    public private(set) var isEnded = false

    /// The page closed for good (its tab closed): as ``close()``, and no later ``reset()`` reopens it, so a
    /// commit, crash or browser end its engine page reports before that page ends serves nothing.
    public func end() {
        isEnded = true
        close()
    }

    /// Ends the current document: its subscriptions, held events and calls.
    private func endDocument() {
        closed = true
        document += 1
        didClose?()
        for stream in held.drain() { reportDropped(stream.events, sub: stream.sub) }
        for subscription in subscriptions.values { subscription.cancel() }
        subscriptions.removeAll()
        activeStreams.removeAll()
        streamProviders.removeAll()
        builtIn.removeAll()
        sequences.removeAll()
        let pending = pendingCalls
        pendingCalls.removeAll()
        for continuation in pending.values { continuation.resume(throwing: PageError.closed) }
        let running = inFlight
        inFlight.removeAll()
        for call in running.values { call.cancel() }
    }

    public var subscriptionCount: Int { subscriptions.count }

    /// The page calls still running (`debug.page` state): page call id, op and age in ms, oldest first.
    public func inFlightCalls(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [JSONValue] {
        inFlight.sorted { $0.key < $1.key }.map { id, call in
            ["id": .number(Double(id)), "op": .string(call.op), "age_ms": .number(((now - call.started) * 1000).rounded())]
        }
    }

    static func error(id: UInt64, _ error: PageError) -> JSONValue {
        var envelope: [String: JSONValue] = [
            "t": "err", "id": .number(Double(id)), "code": .string(error.code), "message": .string(error.message),
            "retryable": .bool(error.retryable),
        ]
        if let details = error.details { envelope["details"] = details }
        return .object(envelope)
    }
}
