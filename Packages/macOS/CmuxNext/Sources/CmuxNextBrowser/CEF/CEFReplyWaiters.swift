import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

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
        let continuation: OnceContinuation<Value, any Error>
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
                // wakeup-allow: deadline of one reply, cancelled when the reply arrives;
                // not a DemandTimer: main actor (timer-class asks MainDeadline, and this type has no MainDeadlineScheduler seam)
                try await clock.sleep(for: timeout, tolerance: WakeLeeway.window(delay: timeout).tolerance)
                failure = timeoutError()
            } catch {
                guard let cancelledError else { return }
                failure = cancelledError()
            }
            self?.settle(key, waiter: id, .failure(failure))
        }
        return try await withTaskCancellationHandler {
            // Waiters dropped with this table unresumed throw OnceContinuationError.abandoned.
            try await withOnceThrowingContinuation { (continuation: OnceContinuation<Value, any Error>) in
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
/// before the caller awaits; a token nobody expects or awaits is dropped, so fire-and-forget async
/// calls hold nothing. A caller in a synchronous turn registers a callback instead
/// (``onReply(_:label:timeout:deadlines:_:)``, task 021), which runs in the turn that delivers the reply.
@MainActor
final class CEFHostReplies {
    /// A callback registered with ``onReply(_:label:timeout:deadlines:_:)`` and its deadline.
    private struct Callback {
        let id: UInt64
        let body: (Result<[UInt8], CEFHostReplyError>) -> Void
        let deadlines: AlignedWakeups
        let deadline: AlignedWakeups.Ticket

        func finish(_ outcome: Result<[UInt8], CEFHostReplyError>) {
            deadlines.cancel(deadline)
            body(outcome)
        }
    }

    /// The `WakeupLedger` owner of the callbacks' deadlines.
    static let callbackDeadlineOwner = "CEFHostReplies.callback"

    private let waiters: CEFReplyWaiters<UInt32, [UInt8]>
    /// Sent, not awaited yet: a reply to one of these is kept in `early`.
    private var expected: Set<UInt32> = []
    /// Answered or failed before anyone awaited.
    private var early: [UInt32: Result<[UInt8], CEFHostReplyError>] = [:]
    /// Callbacks by token, each run once: by the reply, its deadline, ``fail(_:_:)`` or ``failAll(_:)``.
    private var callbacks: [UInt32: Callback] = [:]
    private var lastCallback: UInt64 = 0
    /// This table's entry for the remote shim's reply callback, made at the first attach; it goes with the table.
    private var sinkRegistration: CEFReplySinkRegistration?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        waiters = CEFReplyWaiters(clock: clock, superseded: { CEFHostReplyError.superseded })
    }

    /// The context the remote shim's reply callback gets for this table (``CEFReplySinkRegistration``): the same
    /// token for every attach of the table.
    func replySinkToken() throws(CallbackRegistryError) -> CallbackToken {
        if let sinkRegistration { return sinkRegistration.token }
        let registration = try CEFReplySinkRegistration(self)
        sinkRegistration = registration
        return registration.token
    }

    /// Tokens expected, answered and not taken, awaited, or with a callback.
    var count: Int { waiters.count + expected.count + early.count + callbacks.count }

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

    /// Runs `body` once with the REPLY to `token` in the turn that delivers it, with `timedOut` when
    /// none came `timeout` from now (an entry on `deadlines`, the main thread's deadline queue), or with
    /// the error that fails the token. A reply that came first runs it now. For a caller in a
    /// synchronous turn (an event, a tab's creation): nothing waits on a task of its own.
    func onReply(_ token: UInt32, label: String, timeout: Duration, deadlines: AlignedWakeups,
                 _ body: @escaping (Result<[UInt8], CEFHostReplyError>) -> Void) {
        if let outcome = early.removeValue(forKey: token) { return body(outcome) }
        expected.remove(token)
        lastCallback &+= 1
        let id = lastCallback
        let deadline = deadlines.schedule(owner: Self.callbackDeadlineOwner, after: timeout) { [weak self] in
            self?.expire(token, callback: id, .timedOut(label, timeout))
        }
        // Tokens are unique per request; a reused one fails the older callback.
        callbacks.updateValue(Callback(id: id, body: body, deadlines: deadlines, deadline: deadline), forKey: token)?
            .finish(.failure(.superseded))
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
        let pending = callbacks.values
        callbacks.removeAll()
        for callback in pending { callback.finish(.failure(error)) }
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

    /// The deadline of callback `id` on `token`: fails it when it still waits (not answered or replaced).
    private func expire(_ token: UInt32, callback id: UInt64, _ error: CEFHostReplyError) {
        guard callbacks[token]?.id == id, let callback = callbacks.removeValue(forKey: token) else { return }
        callback.finish(.failure(error))
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
