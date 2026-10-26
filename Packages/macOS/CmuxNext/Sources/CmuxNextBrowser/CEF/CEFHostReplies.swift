import CmuxNextCompat

/// Why an awaited Chromium Host reply did not come.
nonisolated enum CEFHostReplyError: Error, Equatable, Sendable {
    /// The REPLY's fields are not the op's reply shape.
    case malformed
    /// The host exited before it answered (task 091 fails every waiter with it, as a mojo
    /// disconnect runs each pending reply callback's default).
    case hostGone
    /// No reply within the waiter's limit; the label names the op.
    case timedOut(String, Duration)
    /// The awaiting task was cancelled.
    case cancelled
    /// A second wait on the same token took it over.
    case superseded
}

/// Callers awaiting the REPLY of a Chromium Host async op, by its token
/// (plans/cmux-next/chrome-parity/p01-process.md, task 018). In host mode an async export returns
/// as soon as it is sent; its answer (the result, then the out-parameters) comes later in a REPLY
/// frame under the token `cmux_remote_shim_last_reply_token()` gives right after the call. Like a
/// mojo method's reply callback: InterfaceEndpointClient keeps one responder per request id
/// (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc, `async_responders_`) and nothing
/// waits for the other process.
///
/// ```swift
/// guard shim.contentSetting(browser, url, kind) == 1 else { return nil }
/// let token = shim.lastReplyToken()  // cmux_remote_shim_last_reply_token, bound in host mode (task 015)
/// replies.expect(token)
/// let raw = try await replies.reply(to: token, as: Int32.self, label: "content setting", timeout: .seconds(5))
/// ```
///
/// ``resolve(_:fields:)`` runs on any thread (the remote shim's reply callback,
/// remote_shim_runtime.h `cmux_remote_reply_fn`); it decodes there and the awaiting task resumes
/// on its own executor. ``expect(_:)`` keeps a reply that arrives before the caller awaits; a
/// token nobody expects or awaits is dropped, so fire-and-forget async calls hold nothing.
nonisolated final class CEFHostReplies: Sendable {
    private nonisolated struct Waiter: Sendable {
        let finish: @Sendable (Result<[UInt8], CEFHostReplyError>) -> Void
        let deadline: Task<Void, Never>

        func complete(_ outcome: Result<[UInt8], CEFHostReplyError>) {
            deadline.cancel()
            finish(outcome)
        }
    }

    private nonisolated enum Slot: Sendable {
        /// Sent, not awaited yet.
        case expected
        /// Answered or failed before anyone awaited.
        case settled(Result<[UInt8], CEFHostReplyError>)
        case waiting(Waiter)
    }

    /// Lock carve-out: one short compare-and-set of a slot, taken by the reply callback, the
    /// deadline and the cancellation handler, each synchronous; nothing is called under it.
    private let slots = Mutex<[UInt32: Slot]>([:])
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    /// Tokens expected, answered and not taken, or awaited.
    var count: Int { slots.withLock { $0.count } }

    /// Marks `token` as sent, in the turn that sent its op: a reply that comes before
    /// ``reply(to:label:timeout:decode:)`` is kept for it. Await every token you expect.
    func expect(_ token: UInt32) {
        slots.withLock { slots in
            if slots.index(forKey: token) == nil { slots[token] = .expected }
        }
    }

    /// The decoded reply to `token`. `decode` reads the result, then the out-parameters, in the
    /// op's order; a field it leaves unread makes the reply ``CEFHostReplyError/malformed``.
    func reply<Value: Sendable>(
        to token: UInt32, label: String, timeout: Duration,
        decode: @escaping @Sendable (inout CEFHostReplyFields) throws(CEFHostReplyError) -> Value
    ) async throws(CEFHostReplyError) -> Value {
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, CEFHostReplyError>, Never>) in
                wait(token, label: label, timeout: timeout) { reply in
                    continuation.resume(returning: reply.flatMap { Self.decode($0, decode) })
                }
            }
        } onCancel: {
            _ = fail(token, .cancelled)
        }
        return try outcome.get()
    }

    /// The reply to `token` when it is one value (most async ops answer with their int or string result).
    func reply<Value: CEFHostReplyValue>(
        to token: UInt32, as _: Value.Type, label: String, timeout: Duration
    ) async throws(CEFHostReplyError) -> Value {
        try await reply(to: token, label: label, timeout: timeout) {
            (fields: inout CEFHostReplyFields) throws(CEFHostReplyError) -> Value in try Value(reply: &fields)
        }
    }

    /// The REPLY to `token` arrived (the remote shim's reply callback, any thread). False when
    /// nothing expects or awaits it: late, timed out, or never awaited.
    @discardableResult
    func resolve(_ token: UInt32, fields: [UInt8]) -> Bool {
        settle(token, .success(fields))
    }

    /// ``resolve(_:fields:)`` for the remote shim's reply callback: `fields` holds `length` bytes,
    /// valid only during the call, so they are copied first.
    @discardableResult
    func resolve(_ token: UInt32, fields: UnsafeRawPointer?, length: Int) -> Bool {
        let body = fields.map { Array(UnsafeRawBufferPointer(start: $0, count: max(length, 0))) } ?? []
        return resolve(token, fields: body)
    }

    /// Fails the wait for `token`.
    @discardableResult
    func fail(_ token: UInt32, _ error: CEFHostReplyError) -> Bool {
        settle(token, .failure(error))
    }

    /// Fails every token not answered yet (the host exited: ``CEFHostReplyError/hostGone``).
    func failAll(_ error: CEFHostReplyError) {
        let waiters: [Waiter] = slots.withLock { slots in
            var waiters: [Waiter] = []
            for (token, slot) in slots {
                switch slot {
                case .waiting(let waiter):
                    waiters.append(waiter)
                    slots[token] = nil
                case .expected:
                    slots[token] = .settled(.failure(error))
                case .settled:
                    break
                }
            }
            return waiters
        }
        for waiter in waiters { waiter.complete(.failure(error)) }
    }

    private func wait(_ token: UInt32, label: String, timeout: Duration,
                      finish: @escaping @Sendable (Result<[UInt8], CEFHostReplyError>) -> Void) {
        // The slot exists before the deadline starts: a deadline that fires at once settles it.
        let (early, older) = claim(token)
        older?.complete(.failure(.superseded))
        if let early { return finish(early) }
        let clock = clock
        // Holds self until it fires or the reply cancels it, so a waiter never outlives its table.
        let deadline = Task { [self] in
            // wakeup-allow: deadline one-shot limit of one awaited host reply, cancelled when it comes
            do { try await clock.sleep(for: timeout) } catch { return }
            fail(token, .timedOut(label, timeout))
        }
        let waiter = Waiter(finish: finish, deadline: deadline)
        let (ready, displaced): (Result<[UInt8], CEFHostReplyError>?, Waiter?) = slots.withLock { slots in
            switch slots[token] {
            case .settled(let outcome)?:  // the reply, the deadline or a cancellation came meanwhile
                slots[token] = nil
                return (outcome, nil)
            case .waiting(let other)?:  // another wait on the token came meanwhile
                slots[token] = .waiting(waiter)
                return (nil, other)
            case .expected?, nil:
                slots[token] = .waiting(waiter)
                return (nil, nil)
            }
        }
        displaced?.complete(.failure(.superseded))
        if let ready { return waiter.complete(ready) }
        // A cancellation that came before the slot existed found nothing to fail.
        if Task.isCancelled { fail(token, .cancelled) }
    }

    /// Takes `token`'s slot for a new wait: its outcome when one came, otherwise marks it expected
    /// and returns the waiter it takes over.
    private func claim(_ token: UInt32) -> (Result<[UInt8], CEFHostReplyError>?, Waiter?) {
        slots.withLock { slots in
            switch slots[token] {
            case .settled(let outcome)?:
                slots[token] = nil
                return (outcome, nil)
            case .waiting(let older)?:
                slots[token] = .expected
                return (nil, older)
            case .expected?, nil:
                slots[token] = .expected
                return (nil, nil)
            }
        }
    }

    private func settle(_ token: UInt32, _ outcome: Result<[UInt8], CEFHostReplyError>) -> Bool {
        let (matched, waiter): (Bool, Waiter?) = slots.withLock { slots in
            switch slots[token] {
            case .waiting(let waiter)?:
                slots[token] = nil
                return (true, waiter)
            case .expected?:
                slots[token] = .settled(outcome)
                return (true, nil)
            case .settled?, nil:
                return (false, nil)
            }
        }
        waiter?.complete(outcome)
        return matched
    }

    private static func decode<Value>(
        _ body: [UInt8], _ read: (inout CEFHostReplyFields) throws(CEFHostReplyError) -> Value
    ) -> Result<Value, CEFHostReplyError> {
        do throws(CEFHostReplyError) {
            var fields = try CEFHostReplyFields(encoded: body)
            let value = try read(&fields)
            try fields.finish()
            return .success(value)
        } catch {
            return .failure(error)
        }
    }
}

/// A reply that is one value: the op's result with no out-parameters.
nonisolated protocol CEFHostReplyValue: Sendable {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError)
}

nonisolated extension Int32: CEFHostReplyValue {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        self = try fields.int32()
    }
}

nonisolated extension Int64: CEFHostReplyValue {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        self = try fields.int64()
    }
}

/// A `char*` result; nil for NULL.
nonisolated extension Optional: CEFHostReplyValue where Wrapped == String {
    init(reply fields: inout CEFHostReplyFields) throws(CEFHostReplyError) {
        self = try fields.string()
    }
}
