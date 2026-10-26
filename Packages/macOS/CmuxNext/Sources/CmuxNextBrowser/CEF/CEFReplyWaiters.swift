import Foundation

/// Continuations waiting for a reply by key, each with a deadline on the
/// injected clock (architecture.md 5a): a reply that never comes (a page
/// that navigated away, a shim that dropped the message, quit before the
/// browser closed) fails its waiter with `timeoutError` instead of hanging
/// the hover preview, snapshot, or script call that awaited it.
///
/// Each wait has its own identity: its deadline and its cancellation settle
/// only that wait, never a later one on the same key.
@MainActor
final class CEFReplyWaiters<Key: Hashable & Sendable, Value: Sendable> {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Value, any Error>
        let deadline: Task<Void, Never>

        func finish(_ result: Result<Value, any Error>) {
            deadline.cancel()
            continuation.resume(with: result)
        }
    }

    private var waiting: [Key: Waiter] = [:]
    private var lastWaiter: UInt64 = 0
    private let clock: any Clock<Duration>
    private let superseded: @Sendable () -> any Error

    /// `superseded`: the error of a wait that a second wait on its key takes over.
    init(clock: any Clock<Duration> = ContinuousClock(), superseded: @escaping @Sendable () -> any Error = { BrowserTabError.closed }) {
        self.clock = clock
        self.superseded = superseded
    }

    // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14: the
    // isolated deinit's back-deploy path crashed swift-frontend's Release inliner
    // (EarlyPerfInliner, isCallerAndCalleeLayoutConstraintsCompatible) on its deallocating deinit.
    nonisolated deinit {}

    var count: Int { waiting.count }

    /// Suspends until `resolve(key, ...)`, failing with `timeoutError` after `timeout`. With
    /// `cancelledError`, a cancelled caller fails with it at once; without, it waits on.
    func reply(for key: Key, timeout: Duration, timeoutError: @escaping @Sendable () -> any Error,
               cancelledError: (@Sendable () -> any Error)? = nil) async throws -> Value {
        lastWaiter &+= 1
        let id = lastWaiter
        let clock = clock
        // The wait's deadline, and its cancellation: the caller's cancellation cancels this task (from
        // any thread), which then fails the wait on the main actor. It first runs after the wait
        // registers below, in this turn.
        let deadline = Task { [weak self] in
            let failure: any Error
            do {
                // wakeup-allow: one-shot reply deadline on the injected clock, cancelled when the reply arrives
                try await clock.sleep(for: timeout)
                failure = timeoutError()
            } catch {
                guard let cancelledError else { return }
                failure = cancelledError()
            }
            self?.settle(key, waiter: id, .failure(failure))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Keys are unique per request; a reused one fails the older waiter.
                waiting.updateValue(Waiter(id: id, continuation: continuation, deadline: deadline), forKey: key)?
                    .finish(.failure(superseded()))
            }
        } onCancel: {
            if cancelledError != nil { deadline.cancel() }
        }
    }

    /// Resumes the waiter for `key`; false when none waits (late or timed out).
    @discardableResult
    func resolve(_ key: Key, with result: Result<Value, any Error>) -> Bool {
        guard let waiter = waiting.removeValue(forKey: key) else { return false }
        waiter.finish(result)
        return true
    }

    /// Fails every waiter whose key matches.
    func failAll(where matches: (Key) -> Bool, with error: any Error) {
        for key in waiting.keys where matches(key) { resolve(key, with: .failure(error)) }
    }

    /// Resumes the wait `id` on `key` when it still waits: a late deadline or cancellation of a wait
    /// that was answered or taken over settles nothing.
    private func settle(_ key: Key, waiter id: UInt64, _ result: Result<Value, any Error>) {
        guard waiting[key]?.id == id else { return }
        resolve(key, with: result)
    }
}

/// Callers awaiting the REPLY of a Chromium Host async op, by its token
/// (plans/cmux-next/chrome-parity/p01-process.md, task 018). In host mode an async export returns
/// as soon as it is sent; its answer (the result, then the out-parameters) comes later in a REPLY
/// frame under the token ``CEFRemoteShim/lastReplyToken()`` gives right after the call. Like a mojo
/// method's reply callback: InterfaceEndpointClient keeps one responder per request id
/// (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc, `async_responders_`) and nothing
/// waits for the other process.
///
/// ```swift
/// guard shim.contentSetting(browser, url, kind) == 1, let token = host.expectReply() else { return nil }
/// let raw = try await host.replies.reply(to: token, as: Int32.self, label: "content setting", timeout: .seconds(5))
/// ```
///
/// One per runtime, owned by its ``CEFHostStart`` (`host` above), which hands it to the remote
/// shim's reply callback at attach. That callback runs on the main thread
/// (remote_shim_runtime.h `cmux_remote_reply_fn`) and only copies the bytes in;
/// the typed decode runs off main in the awaiting call. ``expect(_:)`` keeps a reply that arrives
/// before the caller awaits; a callback registered with ``onReply(_:label:timeout:_:)`` runs in the
/// turn that delivers the reply. A token nobody expects, awaits or calls back for is dropped, so
/// fire-and-forget async calls hold nothing.
@MainActor
final class CEFHostReplies {
    /// A caller in a synchronous turn: runs once, with the reply, `hostGone` or its deadline.
    private struct Callback {
        let body: (Result<[UInt8], CEFHostReplyError>) -> Void
        let deadline: Task<Void, Never>

        func finish(_ outcome: Result<[UInt8], CEFHostReplyError>) {
            deadline.cancel()
            body(outcome)
        }
    }

    private let waiters: CEFReplyWaiters<UInt32, [UInt8]>
    private let clock: any Clock<Duration>
    /// Sent, not awaited yet: a reply to one of these is kept in `early`.
    private var expected: Set<UInt32> = []
    /// Answered or failed before anyone awaited.
    private var early: [UInt32: Result<[UInt8], CEFHostReplyError>] = [:]
    /// Callbacks by token (``onReply(_:label:timeout:_:)``).
    private var callbacks: [UInt32: Callback] = [:]

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        waiters = CEFReplyWaiters(clock: clock, superseded: { CEFHostReplyError.superseded })
    }

    /// Tokens expected, answered and not taken, awaited, or called back for.
    var count: Int { waiters.count + expected.count + early.count + callbacks.count }

    /// Runs `body` once with the reply to `token`, in the turn that delivers it; with
    /// ``CEFHostReplyError/timedOut(_:_:)`` when none came within `timeout` on the clock, or with
    /// `hostGone` (``failAll(_:)``). Register it in the turn that sent the op. Like a mojo reply
    /// callback, which a disconnect runs with its default (interface_endpoint_client.cc).
    func onReply(_ token: UInt32, label: String, timeout: Duration,
                 _ body: @escaping (Result<[UInt8], CEFHostReplyError>) -> Void) {
        guard token != 0 else { return body(.failure(.cancelled)) }
        let clock = clock
        let deadline = Task { [weak self] in
            // wakeup-allow: one-shot reply deadline on the injected clock, cancelled when the reply arrives
            do { try await clock.sleep(for: timeout) } catch { return }
            self?.callbacks.removeValue(forKey: token)?.body(.failure(.timedOut(label, timeout)))
        }
        callbacks.updateValue(Callback(body: body, deadline: deadline), forKey: token)?.finish(.failure(.superseded))
    }

    /// Calls suspended on a reply now.
    var awaiting: Int { waiters.count }

    /// Marks `token` as sent, in the turn that sent its op: a reply that comes before
    /// ``reply(to:label:timeout:decode:)`` is kept for it. Await every token you expect.
    func expect(_ token: UInt32) {
        guard token != 0, early[token] == nil else { return }
        expected.insert(token)
    }

    /// The decoded reply to `token`. `decode` reads the result, then the out-parameters, in the
    /// op's order, off the main thread; a field it leaves unread makes the reply
    /// ``CEFHostReplyError/malformed``.
    func reply<Value: Sendable>(
        to token: UInt32, label: String, timeout: Duration,
        decode: @escaping @Sendable (inout CEFHostReplyFields) throws(CEFHostReplyError) -> Value
    ) async throws(CEFHostReplyError) -> Value {
        let body = try await fields(of: token, label: label, timeout: timeout)
        return try await Self.decode(body, decode)
    }

    /// The reply to `token` when it is one value (most async ops answer with their int or string result).
    func reply<Value: CEFHostReplyValue>(
        to token: UInt32, as _: Value.Type, label: String, timeout: Duration
    ) async throws(CEFHostReplyError) -> Value {
        try await reply(to: token, label: label, timeout: timeout) {
            (fields: inout CEFHostReplyFields) throws(CEFHostReplyError) -> Value in try Value(reply: &fields)
        }
    }

    /// The REPLY to `token` arrived. False when nothing expects or awaits it: late, timed out, or
    /// never awaited.
    @discardableResult
    func resolve(_ token: UInt32, fields: [UInt8]) -> Bool {
        settle(token, .success(fields))
    }

    /// Fails the wait for `token`.
    @discardableResult
    func fail(_ token: UInt32, _ error: CEFHostReplyError) -> Bool {
        settle(token, .failure(error))
    }

    /// Fails every token not answered yet (the host exited: ``CEFHostReplyError/hostGone``, task 091).
    func failAll(_ error: CEFHostReplyError) {
        let waiting = callbacks
        callbacks.removeAll()
        for callback in waiting.values { callback.finish(.failure(error)) }
        waiters.failAll(where: { _ in true }, with: error)
        for token in expected { early[token] = .failure(error) }
        expected.removeAll()
    }

    private func fields(of token: UInt32, label: String, timeout: Duration) async throws(CEFHostReplyError) -> [UInt8] {
        if let outcome = early.removeValue(forKey: token) { return try outcome.get() }
        expected.remove(token)
        do {
            return try await waiters.reply(for: token, timeout: timeout, timeoutError: { CEFHostReplyError.timedOut(label, timeout) },
                                           cancelledError: { CEFHostReplyError.cancelled })
        } catch {
            // Every error these waiters get is one of the closures above, failAll's or fail's.
            throw error as? CEFHostReplyError ?? .cancelled
        }
    }

    private func settle(_ token: UInt32, _ outcome: Result<[UInt8], CEFHostReplyError>) -> Bool {
        if let callback = callbacks.removeValue(forKey: token) {
            callback.finish(outcome)
            return true
        }
        if waiters.resolve(token, with: outcome.mapError { $0 }) { return true }
        guard expected.remove(token) != nil else { return false }
        early[token] = outcome
        return true
    }

    /// Off the main thread: a password list or a cookie dump is parsed where it cannot delay a frame.
    @concurrent nonisolated private static func decode<Value: Sendable>(
        _ body: [UInt8], _ read: @Sendable (inout CEFHostReplyFields) throws(CEFHostReplyError) -> Value
    ) async throws(CEFHostReplyError) -> Value {
        var fields = try CEFHostReplyFields(encoded: body)
        let value = try read(&fields)
        try fields.finish()
        return value
    }
}
