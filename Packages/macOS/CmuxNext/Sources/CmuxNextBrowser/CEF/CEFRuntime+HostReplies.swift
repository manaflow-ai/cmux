import Foundation

/// How the answer of an async export comes, once the call was made (``CEFRuntime/sendAsync(_:)``).
/// Consume it in the turn that sent it: ``CEFRuntime/answer(_:label:timeout:)`` or
/// ``CEFRuntime/whenAnswered(_:label:timeout:then:)``.
nonisolated enum CEFShimAnswer<Value> {
    /// In process: the call's own result.
    case now(Value)
    /// Host mode: the token of the host's REPLY, expected in ``CEFHostStart/replies``.
    case later(UInt32)
    /// Nothing was sent (no shim, no host attached, or the call sent no op for a reply).
    case unsent
}

nonisolated extension CEFShimAnswer: Sendable where Value: Sendable {}

/// The token form of every async export (plans/cmux-next/chrome-parity/p01-process.md, tasks 018 and
/// 021): one way for both backends, so a caller never reads an answer in the call's turn. In host
/// mode the remote shim returns as soon as it sent the op, and its answer comes in the host's
/// wire:REPLY, which the remote shim's reply callback hands to ``CEFHostStart/replies`` (018's
/// `CEFRemoteReplySink`). Like a mojo reply (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc,
/// `async_responders_`), the answer reaches an awaiting caller or a callback, each with a deadline.
/// `gen-chromium-host-wire.py --swift-sites` counts an async call made inside a closure handed to
/// `sendAsync`, `siteCall` or `profileWrite` as done.
extension CEFRuntime {
    /// Calls an async export with the shim and returns how its answer comes: the result itself in
    /// process, the REPLY token in host mode. A call that sent no op for a reply (refused before the
    /// wire, a mint or a post) leaves the remote's last token as it was: that is `.unsent`, never an
    /// earlier call's token.
    func sendAsync<Value>(_ call: (CEFShimLibrary) -> Value) -> CEFShimAnswer<Value> {
        guard let shim else { return .unsent }
        guard let hostStart else { return .now(call(shim)) }
        guard let remote = hostStart.remote else { return .unsent }
        let before = remote.lastReplyToken()
        _ = call(shim)
        guard remote.lastReplyToken() != before, let token = hostStart.expectReply() else { return .unsent }
        return .later(token)
    }

    /// The answer `sent` stands for: at once in process, the host's REPLY in host mode. Throws
    /// `closed` when nothing was sent or the host went away, `timedOut` past `timeout`.
    func answer<Value: CEFHostReplyValue>(_ sent: CEFShimAnswer<Value>, label: String,
                                          timeout: Duration = CEFRuntime.siteReplyTimeout) async throws(BrowserTabError) -> Value {
        switch sent {
        case .now(let value):
            return value
        case .unsent:
            throw .closed
        case .later(let token):
            guard let replies = hostStart?.replies else { throw .closed }
            do throws(CEFHostReplyError) {
                return try await replies.reply(to: token, as: Value.self, label: label, timeout: timeout)
            } catch {
                throw Self.tabError(error)
            }
        }
    }

    /// Calls `then` once with the answer `sent` stands for (nil: none, a failure, or no answer within
    /// `timeout`, a deadline on the main thread's deadline queue, ``waitDeadlines``): in this turn in
    /// process, in the turn that delivers the host's REPLY in host mode. For a caller in a synchronous
    /// turn; it starts no task.
    func whenAnswered<Value: CEFHostReplyValue>(_ sent: CEFShimAnswer<Value>, label: String,
                                                timeout: Duration = CEFRuntime.siteReplyTimeout,
                                                then: @escaping (Value?) -> Void) {
        whenSettled(sent, label: label, timeout: timeout) { then(try? $0.get()) }
    }

    /// As ``whenAnswered(_:label:timeout:then:)``, with why no answer came, for a caller that must
    /// tell an answer that cannot come (``CEFHostReplyError/hostGone``, ``CEFHostReplyError/unsent``)
    /// from a passed deadline (``CEFHostReplyError/timedOut(_:_:)``: the host may still apply the op,
    /// as a mojo message still runs after its caller stopped waiting).
    func whenSettled<Value: CEFHostReplyValue>(_ sent: CEFShimAnswer<Value>, label: String,
                                               timeout: Duration = CEFRuntime.siteReplyTimeout,
                                               then: @escaping (Result<Value, CEFHostReplyError>) -> Void) {
        switch sent {
        case .now(let value):
            then(.success(value))
        case .unsent:
            then(.failure(.unsent))
        case .later(let token):
            guard let replies = hostStart?.replies else { return then(.failure(.unsent)) }
            replies.onReply(token, label: label, timeout: timeout, deadlines: waitDeadlines) { [logger] reply in
                if case .failure(let error) = reply {
                    logger.notice("Chromium Host \(label, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                then(Self.decoded(reply))
            }
        }
    }

    /// The host exited (task 091 calls this in the exit turn): every reply still awaited fails with
    /// `hostGone`, and every profile proxy is handed to the next host again before a page of its
    /// profile opens. A host's verdict on a proxy says nothing about the host after it, whose
    /// Chromium context starts without the proxy (#24432 fails closed).
    func hostGone() {
        hostStart?.replies.failAll(.hostGone)
        profileProxyChecks.removeAll()
        unappliedProfileProxies.formUnion(profileProxies.keys)
    }

    private static func tabError(_ error: CEFHostReplyError) -> BrowserTabError {
        if case .timedOut(let what, let limit) = error { return .timedOut("Chromium Host \(what) (\(limit))") }
        return .closed
    }

    private static func decoded<Value: CEFHostReplyValue>(_ reply: Result<[UInt8], CEFHostReplyError>) -> Result<Value, CEFHostReplyError> {
        do throws(CEFHostReplyError) {
            return .success(try decode(reply.get()))
        } catch {
            return .failure(error)
        }
    }

    /// One value from a REPLY body: the op's result and nothing after it.
    private static func decode<Value: CEFHostReplyValue>(_ body: [UInt8]) throws(CEFHostReplyError) -> Value {
        var fields = try CEFHostReplyFields(encoded: body)
        let value = try Value(reply: &fields)
        try fields.finish()
        return value
    }
}
