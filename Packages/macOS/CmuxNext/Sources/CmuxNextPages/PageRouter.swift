public import CmuxNextSettings
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
    private var routes: [PageRoute]
    /// Runs one envelope in the page (`window.__cmuxPageReceive(<json>)`).
    public var send: ((JSONValue) -> Void)?
    private var subscriptions: [UInt64: PageSubscription] = [:]
    private var sequences: [UInt64: UInt64] = [:]
    private var nextSubscription: UInt64 = 1
    private var nextCall: UInt64 = 1
    private var pendingCalls: [UInt64: CheckedContinuation<JSONValue, any Error>] = [:]
    /// Page calls still running, by page call id: cancelled by the page's `cancel` envelope, by
    /// navigation (`reset`) and by tab close (`close`) (app-op-routing.md "Op cancel").
    private var inFlight: [UInt64: PageCallInFlight] = [:]
    private var closed = false
    /// Built-in streams every page gets (``PageNativeOp/pageCommand``, ``PageNativeOp/pageConnection``):
    /// subscription id to stream name.
    private var builtIn: [UInt64: String] = [:]
    /// The owner link state the connection stream reports.
    public private(set) var connected = true

    public init(descriptor: PageDescriptor, routes: [PageRoute]) {
        self.descriptor = descriptor
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// Rebinds a pooled router to a new document and ends every operation owned by the old page.
    func rebind(descriptor: PageDescriptor, routes: [PageRoute]) {
        reset()
        self.descriptor = descriptor
        self.routes = routes.sorted { $0.prefix.count > $1.prefix.count }
    }

    /// The script that delivers `envelope` to the page.
    public nonisolated static func receiveScript(_ envelope: JSONValue) -> String {
        "window.__cmuxPageReceive && window.__cmuxPageReceive(\(envelope.compactText));"
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
                let value = try await cancellable(id: id) { [self] in try await call(op, params: params, opid: opid) }
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

    /// Whether a real key or mouse event reached the page's view just now (PageWKWebView); nil in
    /// tests without a view.
    public var hasUserGesture: (@MainActor () -> Bool)?

    /// The window's title bar action (DESKTOP-FEEL): a double-click on a title bar the page draws.
    public var titleBarDoubleClick: (@MainActor () -> Void)?

    private func call(_ op: String, params: JSONValue, opid: String?) async throws -> JSONValue {
        if op == PageNativeOp.titleBarDoubleClick {
            guard !closed else { throw PageError.closed }
            titleBarDoubleClick?()
            return .object([:])
        }
        let (provider, params) = try admit(op, params: params)
        return try await provider.call(op, params: params, context: PageCallContext(page: descriptor.id, opid: opid,
                                                                                     userGesture: hasUserGesture?() ?? false))
    }

    /// Runs `work` as page call `id`, answering `cmux.op.cancelled` at once when the call is
    /// cancelled; the work's task is cancelled too, so the owner stops (a relay cancels its op).
    private func cancellable(id: UInt64, _ work: @escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue {
        let call = PageCallInFlight()
        inFlight[id] = call
        defer { if inFlight[id] === call { inFlight[id] = nil } }
        return try await withCheckedThrowingContinuation { continuation in
            call.start(continuation, work)
        }
    }

    private func subscribe(_ stream: String, filter: JSONValue) async throws -> UInt64 {
        if stream == PageNativeOp.pageCommand || stream == PageNativeOp.pageConnection {
            guard !closed else { throw PageError.closed }
            let sub = nextSubscription
            nextSubscription += 1
            builtIn[sub] = stream
            if stream == PageNativeOp.pageConnection {
                // The current state, after the subscribe reply that names `sub` reaches the page.
                let connected = connected
                // task-owner: one event delivery after the reply; ends with the router
                Task { @MainActor [weak self] in self?.deliver(sub: sub, ["connected": .bool(connected)]) }
            }
            return sub
        }
        let (provider, filter) = try admit(stream, params: filter)
        let sub = nextSubscription
        nextSubscription += 1
        // A provider may send its current state from inside `subscribe` (the icon picker's open
        // session). Those events wait until the reply that names `sub` reaches the page.
        let early = PageEarlyEvents()
        let subscription = try await provider.subscribe(stream, filter: filter, context: PageCallContext(page: descriptor.id)) { [weak self] data in
            if early.hold(data) { return }
            self?.deliver(sub: sub, data)
        }
        guard !closed else {
            subscription.cancel()
            throw PageError.closed
        }
        subscriptions[sub] = subscription
        // Nothing held: later events go straight to the page. Otherwise they queue behind the held
        // ones until the flush, which runs after the reply.
        guard early.isHolding else {
            _ = early.release()
            return sub
        }
        // task-owner: one flush after the reply; ends with the router
        Task { @MainActor [weak self] in
            for data in early.release() { self?.deliver(sub: sub, data) }
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

    private func deliver(sub: UInt64, _ data: JSONValue) {
        guard subscriptions[sub] != nil || builtIn[sub] != nil else { return }
        let seq = (sequences[sub] ?? 0) + 1
        sequences[sub] = seq
        send?(["t": "ev", "sub": .number(Double(sub)), "seq": .number(Double(seq)), "data": data])
    }

    private func unsubscribe(_ sub: UInt64) {
        subscriptions.removeValue(forKey: sub)?.cancel()
        builtIn.removeValue(forKey: sub)
        sequences.removeValue(forKey: sub)
    }

    // MARK: Built-in streams

    /// Sends a dispatcher command to the page's command subscribers. False when the command is
    /// not a page command or no subscriber listens.
    @discardableResult
    public func publishCommand(_ command: String, arguments: [String: JSONValue] = [:]) -> Bool {
        guard descriptor.commands.contains(command) else { return false }
        var data = arguments
        data["command"] = .string(command)
        let subs = builtIn.filter { $0.value == PageNativeOp.pageCommand }.keys.sorted()
        for sub in subs { deliver(sub: sub, .object(data)) }
        return !subs.isEmpty
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
        for subscription in subscriptions.values { subscription.cancel() }
        subscriptions.removeAll()
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
    private var continuation: CheckedContinuation<JSONValue, any Error>?
    private var task: Task<Void, Never>?
    private var cancelled = false

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
