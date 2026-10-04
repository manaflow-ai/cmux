public import CmuxNextSettings
public import Foundation

/// The host half of a page's bridge, engine neutral: it reads pane-protocol envelopes
/// (plans/cmux-next/pane-protocol.md "Wire") from the page, checks them against the page's
/// ``PageDescriptor``, routes calls and subscriptions to providers, and pushes events and host
/// calls back through `send`. The engine bridge (``PageHostBridge``) only carries bytes.
///
/// Rules every page gets here, so no provider repeats them:
/// - only ops and streams the descriptor admits reach a provider; the rest is `unknown_op`;
/// - params must be an object; an `origin` the page sends is refused (the host stamps `user`);
/// - events of one subscription are numbered from 1; an unsubscribe or ``close()`` cancels.
@MainActor
public final class PageRouter {
    public let descriptor: PageDescriptor
    private let routes: [PageRoute]
    /// Runs one envelope in the page (`window.__cmuxPageReceive(<json>)`).
    public var send: ((JSONValue) -> Void)?
    private var subscriptions: [UInt64: PageSubscription] = [:]
    private var sequences: [UInt64: UInt64] = [:]
    private var nextSubscription: UInt64 = 1
    private var nextCall: UInt64 = 1
    private var pendingCalls: [UInt64: CheckedContinuation<JSONValue, any Error>] = [:]
    private var closed = false

    public init(descriptor: PageDescriptor, routes: [PageRoute]) {
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
                let value = try await call(op, params: message["params"] ?? .object([:]))
                return ["t": "ok", "id": .number(Double(id)), "value": value]
            } catch let error as PageError {
                return Self.error(id: id, error)
            } catch {
                return Self.error(id: id, PageError(code: "cmux.page.failed", message: String(describing: error)))
            }
        case "sub":
            guard let stream = message["stream"]?.stringValue else { return Self.error(id: id, .invalidParams("missing stream")) }
            do {
                let sub = try await subscribe(stream)
                return ["t": "ok", "id": .number(Double(id)), "value": ["sub": .number(Double(sub))]]
            } catch let error as PageError {
                return Self.error(id: id, error)
            } catch {
                return Self.error(id: id, PageError(code: "cmux.page.failed", message: String(describing: error)))
            }
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

    private func call(_ op: String, params: JSONValue) async throws -> JSONValue {
        let (provider, params) = try admit(op, params: params)
        return try await provider.call(op, params: params, context: PageCallContext(page: descriptor.id))
    }

    private func subscribe(_ stream: String) async throws -> UInt64 {
        let (provider, _) = try admit(stream, params: .object([:]))
        let sub = nextSubscription
        nextSubscription += 1
        let subscription = try await provider.subscribe(stream, context: PageCallContext(page: descriptor.id)) { [weak self] data in
            self?.deliver(sub: sub, data)
        }
        guard !closed else {
            subscription.cancel()
            throw PageError.unavailable("page closed")
        }
        subscriptions[sub] = subscription
        return sub
    }

    private func admit(_ op: String, params: JSONValue) throws -> (any PageProvider, JSONValue) {
        guard !closed else { throw PageError.unavailable("page closed") }
        guard descriptor.admits(op), let route = routes.first(where: { op.hasPrefix($0.prefix) }) else {
            throw PageError.unknownOp(op)
        }
        guard case .object(let members) = params else { throw PageError.invalidParams("params must be an object") }
        guard members["origin"] == nil else { throw PageError.invalidParams("origin is set by the host") }
        return (route.provider, params)
    }

    private func deliver(sub: UInt64, _ data: JSONValue) {
        guard subscriptions[sub] != nil else { return }
        let seq = (sequences[sub] ?? 0) + 1
        sequences[sub] = seq
        send?(["t": "ev", "sub": .number(Double(sub)), "seq": .number(Double(seq)), "data": data])
    }

    private func unsubscribe(_ sub: UInt64) {
        subscriptions.removeValue(forKey: sub)?.cancel()
        sequences.removeValue(forKey: sub)
    }

    // MARK: Host to page

    /// Calls an op the page serves (`cmux.page.command`) and waits for its reply.
    public func callPage(_ op: String, params: JSONValue) async throws -> JSONValue {
        guard !closed, let send else { throw PageError.unavailable("page not loaded") }
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
        sequences.removeAll()
        let pending = pendingCalls
        pendingCalls.removeAll()
        for continuation in pending.values { continuation.resume(throwing: PageError.unavailable("page closed")) }
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
