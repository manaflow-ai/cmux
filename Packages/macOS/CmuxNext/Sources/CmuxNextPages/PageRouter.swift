public import CmuxNextSettings
public import Foundation
import os

/// The host half of a page's bridge, engine neutral: it reads pane-protocol envelopes
/// (plans/cmux-next/pane-protocol.md "Wire") from the page, checks them against the page's
/// ``PageDescriptor``, routes calls and subscriptions to providers, and pushes events and host
/// calls back through `send`. The engine bridge (``PageHostBridge``) only carries bytes.
///
/// Rules every page gets here, so no provider repeats them:
/// - only ops and streams the descriptor admits reach a provider; the rest is `unknown_op`;
/// - the router's own host ops and streams run only for a page it serves them
///   (``PageDescriptor/servesHostOps``) or whose descriptor admits them: an app page's messages
///   all pass its admission first;
/// - params must be an object; an `origin` or a confirmation the page sends is refused (the host
///   stamps `page`; only a native confirmation sheet makes a call the user's);
/// - events of one subscription are numbered from 1; an unsubscribe or ``close()`` cancels.
@MainActor
public final class PageRouter {
    public private(set) var descriptor: PageDescriptor
    private var routes: [PageRoute]
    /// Runs one envelope in the page (`window.__cmuxPageReceive(<json>)`).
    public var send: ((JSONValue) -> Void)?
    /// Script pipeline entry that reports envelopes dropped by a page reset.
    public var sendWithDrop: ((JSONValue, @escaping @MainActor () -> Void) -> Void)?
    /// Runs at every ``close()`` (and so at ``reset()`` and rebind): the host drops envelopes it
    /// has not delivered yet, which belong to the subscriptions that just ended.
    public var didClose: (() -> Void)?
    private var subscriptions: [UInt64: PageSubscription] = [:]
    private var activeStreams: Set<UInt64> = []
    private var streamProviders: [UInt64: (name: String, provider: any PageProvider)] = [:]
    private var sequences: [UInt64: UInt64] = [:]
    private var nextSubscription: UInt64 = 1
    private var nextCall: UInt64 = 1
    private var pendingCalls: [UInt64: CheckedContinuation<JSONValue, any Error>] = [:]
    /// Page calls still running, by page call id: cancelled by the page's `cancel` envelope, by
    /// navigation (`reset`) and by tab close (`close`) (app-op-routing.md "Op cancel").
    private var inFlight: [UInt64: PageCallInFlight] = [:]
    private(set) var closed = false
    /// Built-in streams every page gets (``PageNativeOp/pageCommand``, ``PageNativeOp/pageConnection``):
    /// subscription id to stream name.
    private(set) var builtIn: [UInt64: String] = [:]
    /// The owner link state the connection stream reports.
    public private(set) var connected = true

    public init(descriptor: PageDescriptor, routes: [PageRoute]) {
        self.descriptor = descriptor
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// Rebinds a pooled router to a new document and ends every operation owned by the old page.
    func rebind(descriptor: PageDescriptor, routes: [PageRoute]) {
        reset()
        heldCommand = nil  // meant for the old document
        self.descriptor = descriptor
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// The script that delivers `envelope` to the page.
    /// One buffer: the envelope's JSON is appended in place, never built and copied.
    public nonisolated static func receiveScript(_ envelope: JSONValue) -> String {
        var script = "window.__cmuxPageReceive && window.__cmuxPageReceive("
        envelope.appendCompactText(to: &script)
        script += ");"
        return script
    }

    // MARK: Page to host

    /// A page's call or subscription id: an integer in 1 ... 2^53 - 1 (the JSON-safe range the protocol
    /// allows), nil for anything else. The page posts any JSON number (`Infinity` and `1e30` are valid
    /// script values) and `UInt64(_:)` traps outside 0 ..< 2^64.
    nonisolated static func wireID(_ value: Double) -> UInt64? {
        guard value >= 1, value <= 9_007_199_254_740_991, value == value.rounded(.towardZero) else { return nil }
        return UInt64(value)
    }

    /// Handles one envelope the page posted and returns the reply envelope (or `null` for
    /// messages that need none: `unsub`, and replies to host calls).
    public func handle(_ message: JSONValue) async -> JSONValue {
        guard let type = message["t"]?.stringValue else { return Self.error(id: 0, .invalidParams("missing t")) }
        var id: UInt64 = 0
        if let raw = message["id"]?.doubleValue {
            guard let valid = Self.wireID(raw) else {
                // An invalid id names no operation: a call or subscription is refused (never run under
                // id 0, where invalid ids would collide); anything else needs no reply.
                guard type == "call" || type == "sub" else { return .null }
                return Self.error(id: 0, PageError(code: "cmux.protocol.bad_message", message: "id must be an integer from 1 to 2^53 - 1"))
            }
            id = valid
        }
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
                let value = try await cancellable(id: id, op: op) { [self] in try await call(op, params: params, opid: opid) }
                return ["t": "ok", "id": .number(Double(id)), "value": value]
            } catch let error as PageError {
                return Self.error(id: id, error)
            } catch {
                return Self.error(id: id, failure(error, in: op))
            }
        case "sub":
            guard let stream = message["stream"]?.stringValue else { return Self.error(id: id, .invalidParams("missing stream")) }
            do {
                let sub = try await subscribe(stream, filter: message["filter"] ?? .object([:]))
                return ["t": "ok", "id": .number(Double(id)), "value": ["sub": .number(Double(sub))]]
            } catch let error as PageError {
                return Self.error(id: id, error)
            } catch {
                return Self.error(id: id, failure(error, in: stream))
            }
        case "cancel":
            // A cancel of an unknown or finished id is a no-op; it gets no reply.
            inFlight[id]?.cancel()
            return .null
        case "unsub":
            if let sub = message["sub"]?.doubleValue.flatMap(Self.wireID) { unsubscribe(sub) }
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
    /// Go Back (true) or Go Forward (false) for the page's swipe gesture `g` (`cmux.app.history.navigate`);
    /// true when it ran.
    public var historyNavigate: (@MainActor (_ back: Bool, _ gesture: Int) -> Bool)?
    /// The page is done with forwarded swipe gesture `g` (`cmux.app.swipe.release`): stop sending it.
    public var swipeRelease: (@MainActor (Int) -> Void)?

    /// The page's heartbeat (``PageNativeOp/pageHeartbeat``) with its handled-input count, whether
    /// it holds unsaved edits and whether it now rests (beats no more until something happens in it):
    /// the page view feeds app health. Returns whether the host takes rest beats (the page may stop
    /// beating). Nil (tests, a view not wired) still answers the beat.
    public var heartbeat: (@MainActor (_ handled: UInt64, _ edits: Bool, _ rest: Bool) -> Bool)?

    /// A popup op (`cmux.app.popup.*`, cx-6k6cg) with its params: the page view's WebPopupHost.
    public var popup: (@MainActor (String, [String: Any]) -> JSONValue)?

    /// A right-click menu (`cmux.app.contextMenu.show`) with its params: the page view's native
    /// menu, answered once it closes.
    public var contextMenu: (@MainActor ([String: Any]) async -> JSONValue)?

    private func call(_ op: String, params: JSONValue, opid: String?) async throws -> JSONValue {
        // Admission first: a page the router serves no host ops (an app page) reaches only what its
        // descriptor admits, so its messages go straight to ``admit(_:params:)``.
        guard descriptor.admitsHostOp(op) else { return try await routed(op, params: params, opid: opid) }
        if let reply = try hostCall(op, params: params) { return reply }
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
        return try await routed(op, params: params, opid: opid)
    }

    /// A call to the provider whose route serves `op`, once the descriptor admits it.
    private func routed(_ op: String, params: JSONValue, opid: String?) async throws -> JSONValue {
        let (provider, params, _) = try admit(op, params: params)
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
        return try await withCheckedThrowingContinuation { continuation in
            call.start(continuation, work)
        }
    }

    private func subscribe(_ stream: String, filter: JSONValue) async throws -> UInt64 {
        if PageNativeOp.builtInStreams.contains(stream), descriptor.admitsHostOp(stream) {
            guard !closed else { throw PageError.closed }
            let sub = nextSubscription
            nextSubscription += 1
            builtIn[sub] = stream
            if stream == PageNativeOp.pageCommand { deliverHeldCommand() }
            if stream == PageNativeOp.pageConnection {
                // The current state, after the subscribe reply that names `sub` reaches the page.
                let connected = connected
                // task-owner: one event delivery after the reply; ends with the router
                Task { @MainActor [weak self] in self?.deliver(sub: sub, ["connected": .bool(connected)]) }
            }
            return sub
        }
        let (provider, filter, view) = try admit(stream, params: filter)
        let sub = nextSubscription
        nextSubscription += 1
        activeStreams.insert(sub)
        if let view { viewStreams[view, default: []].insert(sub) }
        streamProviders[sub] = (stream, provider)
        // A provider may send its current state from inside `subscribe` (the icon picker's open
        // session). Those events wait until the reply that names `sub` reaches the page.
        let early = PageEarlyEvents()
        // One owner frees it on every exit: the posted flush below takes it over; every other exit (a
        // throw, the page closed meanwhile, nothing held) releases it here, so a provider that keeps
        // `onEvent` after its subscription ended adds nothing to a list nobody reads.
        var flushesAfterReply = false
        defer { if !flushesAfterReply { _ = early.release() } }
        let subscription: PageSubscription
        do {
            subscription = try await provider.subscribe(stream, filter: filter, context: PageCallContext(page: descriptor.id)) { [weak self] data in
                if !provider.eventsAfterSubscribeReply, early.hold(data) { return }
                self?.deliver(sub: sub, data, publicationID: provider.eventDeliveryID)
            }
        } catch {
            activeStreams.remove(sub)
            streamProviders.removeValue(forKey: sub)
            if let view { viewStreams[view]?.remove(sub) }
            throw error
        }
        guard !closed else {
            subscription.cancel()
            activeStreams.remove(sub)
            streamProviders.removeValue(forKey: sub)
            if let view { viewStreams[view]?.remove(sub) }
            throw PageError.closed
        }
        // The view went away while its provider subscribed (``removeView(_:)`` ended the stream).
        guard activeStreams.contains(sub) else {
            subscription.cancel()
            throw PageError(code: Self.unknownViewCode, message: "view \(view ?? "") closed")
        }
        activeStreams.remove(sub)
        subscriptions[sub] = subscription
        // Nothing held (or a provider that sends only after the reply): later events go straight to
        // the page. Otherwise they queue behind the held ones until the flush, which runs after the reply.
        guard early.isHolding, !provider.eventsAfterSubscribeReply else {
            _ = early.release()
            return sub
        }
        flushesAfterReply = true
        // task-owner: one flush after the reply; ends with the router
        Task { @MainActor [weak self] in
            for data in early.release() { self?.deliver(sub: sub, data, publicationID: provider.eventDeliveryID) }
        }
        return sub
    }

    /// The provider for `op` and the params it gets. While the page serves views (``addView(_:routes:)``),
    /// a `view` field names the chat the call or subscription is for: that view's routes serve it first,
    /// then the page's own, and the field is taken out (the host knows the view by its provider). A page
    /// with no views passes `view` through untouched, as before views existed.
    private func admit(_ op: String, params: JSONValue) throws -> (any PageProvider, JSONValue, String?) {
        guard !closed else { throw PageError.closed }
        guard descriptor.admits(op) else { throw PageError.unknownOp(op) }
        guard case .object(var members) = params else { throw PageError.invalidParams("params must be an object") }
        for reserved in ["origin", "confirmed", "confirmation"] where members[reserved] != nil {
            throw PageError.invalidParams("\(reserved) is set by the host")
        }
        var view: String?
        if !views.isEmpty, let named = members[Self.viewField], named != .null {
            guard let id = named.stringValue, let viewRoutes = views[id] else {
                throw PageError(code: Self.unknownViewCode, message: "no view \(named) serves \(op)")
            }
            members[Self.viewField] = nil
            if let route = viewRoutes.first(where: { op.hasPrefix($0.prefix) }) {
                return (route.provider, .object(members), id)
            }
            view = id
        }
        guard let route = routes.first(where: { op.hasPrefix($0.prefix) }) else { throw PageError.unknownOp(op) }
        return (route.provider, view == nil ? params : .object(members), view)
    }

    // MARK: Views

    /// The params and filter field that names a view (webviews `paneView.ts` `VIEW_FIELD`).
    public nonisolated static let viewField = "view"
    /// The error a call or subscription naming no live view gets (as the page's own view router).
    public nonisolated static let unknownViewCode = "cmux.agent.view.unknown"
    /// The views the page serves (goal memory-per-chat: a pane's chats as views of one document),
    /// each with its own routes, longest prefix first.
    private var views: [String: [PageRoute]] = [:]
    /// The subscriptions each view opened, so removing the view ends them.
    private var viewStreams: [String: Set<UInt64>] = [:]

    /// The views the page serves now, sorted.
    public var viewIDs: [String] { views.keys.sorted() }

    /// Serves `view` with `routes` (its chat's providers); a view already served gets the new routes
    /// after its old ones end (``removeView(_:)``).
    public func addView(_ view: String, routes: [PageRoute]) {
        if views[view] != nil { removeView(view) }
        views[view] = routes.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// Stops serving `view` (its chat closed or left the document): its subscriptions end and its own
    /// providers drop what they hold for the page (``PageProvider/pageDidClose()``). Later calls naming
    /// it get ``unknownViewCode``.
    public func removeView(_ view: String) {
        guard let removed = views.removeValue(forKey: view) else { return }
        for sub in (viewStreams.removeValue(forKey: view) ?? []).sorted() { unsubscribe(sub) }
        let shared = Set(routes.map { ObjectIdentifier($0.provider) })
        var notified = Set<ObjectIdentifier>()
        for route in removed {
            let identity = ObjectIdentifier(route.provider)
            guard !shared.contains(identity), notified.insert(identity).inserted else { continue }
            route.provider.pageDidClose()
        }
    }

    /// Calls `op` on the page for `view`: the page's view router hands it to that view's handler.
    public func callPage(_ op: String, params: JSONValue, view: String) async throws -> JSONValue {
        guard case .object(var members) = params else { throw PageError.invalidParams("params must be an object") }
        members[Self.viewField] = .string(view)
        return try await callPage(op, params: .object(members))
    }

    func deliver(sub: UInt64, _ data: JSONValue, publicationID: UInt64? = nil) {
        guard subscriptions[sub] != nil || builtIn[sub] != nil || activeStreams.contains(sub) else { return }
        let seq = (sequences[sub] ?? 0) + 1
        sequences[sub] = seq
        let envelope: JSONValue = ["t": "ev", "sub": .number(Double(sub)), "seq": .number(Double(seq)), "data": data]
        let stream = streamProviders[sub]
        let dropped = { @MainActor in
            guard let stream else { return }
            stream.provider.eventDeliveryDropped(stream: stream.name, data: data, publicationID: publicationID)
        }
        if let sendWithDrop { sendWithDrop(envelope, dropped) } else { send?(envelope) }
    }

    private func unsubscribe(_ sub: UInt64) {
        for view in viewStreams.keys { viewStreams[view]?.remove(sub) }
        subscriptions.removeValue(forKey: sub)?.cancel()
        activeStreams.remove(sub)
        streamProviders.removeValue(forKey: sub)
        builtIn.removeValue(forKey: sub)
        sequences.removeValue(forKey: sub)
    }

    // MARK: Built-in streams

    /// Sends a dispatcher command to the page's command subscribers. False when the command is
    /// not a page command, or no subscriber listens and the command is not one of
    /// ``heldUntilReady``: those (Cmd-F's `find`) wait for a page that still loads, the newest
    /// one only, and reach it when it subscribes to its command stream (true).
    @discardableResult
    public func publishCommand(_ command: String, arguments: [String: JSONValue] = [:],
                               now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard descriptor.commands.contains(command) else { return false }
        var data = arguments
        data["command"] = .string(command)
        let subs = builtIn.filter { $0.value == PageNativeOp.pageCommand }.keys.sorted()
        for sub in subs { deliver(sub: sub, .object(data)) }
        if !subs.isEmpty { heldCommand = nil; return true }
        // CMD-F FIRST PRESS (user 2026-11-15): the first Cmd-F after a launch or a tab switch came
        // while the page loaded and was lost; the second worked.
        guard Self.heldUntilReady.contains(command), !closed else { return false }
        heldCommand = (.object(data), now)
        return true
    }

    /// The commands a page that still loads gets once it listens (``publishCommand(_:arguments:now:)``).
    nonisolated static let heldUntilReady: Set<String> = ["find", "focusSearch"]
    /// How long a held command waits for its page: past it, a page that never loaded in time
    /// (a crash, a hang) does not open Find long after the press.
    public nonisolated static let heldCommandLifetime: TimeInterval = 10
    /// The command waiting for the page's first command subscription, and when it was sent.
    private var heldCommand: (data: JSONValue, sent: TimeInterval)?

    /// Delivers the held command to the command subscribers after the subscribe reply reaches the page.
    private func deliverHeldCommand() {
        guard let held = heldCommand else { return }
        heldCommand = nil
        guard ProcessInfo.processInfo.systemUptime - held.sent <= Self.heldCommandLifetime else { return }
        // task-owner: one event delivery after the reply; ends with the router
        // main-hop-allow: the event must follow the subscribe reply that names its sub, which the bridge sends after subscribe returns (as the connection stream's first event above); one delivery of one held command
        Task { @MainActor [weak self] in
            guard let self else { return }
            for sub in builtIn.filter({ $0.value == PageNativeOp.pageCommand }).keys.sorted() { deliver(sub: sub, held.data) }
        }
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

    /// Calls an op the page serves (`cmux.page.command`) and waits for its reply.
    public func callPage(_ op: String, params: JSONValue) async throws -> JSONValue {
        guard !closed, let send else { throw PageError.closed }
        let id = nextCall
        nextCall += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[id] = continuation
            send(["t": "call", "id": .number(Double(id)), "op": .string(op), "params": params])
        }
    }

    private func resolve(id: UInt64, _ message: JSONValue) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        if message["t"]?.stringValue == "ok" {
            continuation.resume(returning: message["value"] ?? .null)
        } else {
            continuation.resume(throwing: PageError(
                code: message["code"]?.stringValue ?? "cmux.page.failed", message: message["message"]?.stringValue ?? ""))
        }
    }

    /// The page went away (tab closed, reload): cancels every subscription and fails pending calls.
    public func close() {
        closed = true
        didClose?()
        var notified = Set<ObjectIdentifier>()
        for route in routes + views.keys.sorted().flatMap({ views[$0] ?? [] }) {
            let provider = route.provider
            let identity = ObjectIdentifier(provider)
            if notified.insert(identity).inserted { provider.pageDidClose() }
        }
        // The views stay served (the host owns them); a reloaded document mounts them again.
        viewStreams.removeAll()
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

    /// Reopens after a reload of the same page (a new document starts with no subscriptions).
    public func reset() {
        close()
        closed = false
    }

    public var subscriptionCount: Int { subscriptions.count }

    /// The page calls still running (`debug.page` state): page call id, op and age in ms, oldest first.
    public func inFlightCalls(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [JSONValue] {
        inFlight.sorted { $0.key < $1.key }.map { id, call in
            ["id": .number(Double(id)), "op": .string(call.op), "age_ms": .number(((now - call.started) * 1000).rounded())]
        }
    }

    /// A provider's failure that is not a ``PageError``: logged with its Debug text, answered with
    /// the fixed message (``PageError/failed(_:code:retryable:)``).
    private func failure(_ error: any Error, in name: String) -> PageError {
        Self.logger.error("page \(self.descriptor.id, privacy: .public) \(name, privacy: .public) failed: \(String(describing: error))")
        return .failed(error)
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "page")

    static func error(id: UInt64, _ error: PageError) -> JSONValue {
        var envelope: [String: JSONValue] = [
            "t": "err", "id": .number(Double(id)), "code": .string(error.code), "message": .string(error.message),
            "retryable": .bool(error.retryable),
        ]
        if let details = error.details { envelope["details"] = details }
        return .object(envelope)
    }
}

/// One page call in flight: its work's task and the continuation the router answers. The first of
/// the work's end and a cancel answers it (once); a cancel also cancels the task.
@MainActor
final class PageCallInFlight {
    let op: String
    /// When the call arrived (`systemUptime`).
    let started = ProcessInfo.processInfo.systemUptime
    private var continuation: CheckedContinuation<JSONValue, any Error>?
    private var task: Task<Void, Never>?
    private var cancelled = false

    init(op: String) {
        self.op = op
    }

    func start(_ continuation: CheckedContinuation<JSONValue, any Error>, _ work: @escaping @MainActor () async throws -> JSONValue) {
        self.continuation = continuation
        guard !cancelled else { return finish(.failure(PageError.opCancelled)) }
        // task-owner: one page call; ends with its work or the page's cancel (navigation, tab close)
        task = Task { @MainActor [weak self] in
            let result: Result<JSONValue, any Error>
            do { result = .success(try await work()) } catch { result = .failure(error) }
            self?.finish(result)
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        finish(.failure(PageError.opCancelled))
    }

    private func finish(_ result: Result<JSONValue, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Events a provider sends before its subscription is registered and answered: held in order,
/// then released once, after which events go straight to the page.
@MainActor
final class PageEarlyEvents {
    private var held: [JSONValue]? = []

    /// Whether any event is held (the subscription is not released and something arrived).
    var isHolding: Bool { !(held?.isEmpty ?? true) }

    /// Holds `data` while the subscription is not released yet; false once it is.
    func hold(_ data: JSONValue) -> Bool {
        guard held != nil else { return false }
        held?.append(data)
        return true
    }

    /// The held events, oldest first; later events are not held.
    func release() -> [JSONValue] {
        defer { held = nil }
        return held ?? []
    }
}
