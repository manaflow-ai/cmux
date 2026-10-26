import Foundation

/// Host mode's way to the answer of an async export (plans/cmux-next/chrome-parity/p01-process.md,
/// tasks 018 and 021). The remote shim returns as soon as it sent the op, and
/// `cmux_remote_shim_last_reply_token()`, read right after the call, names the wire:REPLY that
/// carries the result and the out-parameters.
///
/// The route reads tokens; the answers land in ``replies``, the runtime's one table, which the
/// attached remote shim's reply callback resolves (``CEFHostStart/replies``,
/// ``CEFRemoteShim/attach(_:replies:helloDeadline:clock:)``). A reply reaches its caller one of two
/// ways, as a mojo reply does (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc,
/// `async_responders_`): a callback (``CEFHostReplies/onReply(_:label:timeout:_:)``) runs in the turn
/// that delivers the REPLY, so a caller in a synchronous turn needs no task of its own; otherwise an
/// async caller awaiting ``replies`` resumes. Both have a deadline. Nothing waits for the host.
final class CEFHostReplyRoute {
    typealias LastReplyTokenFn = @convention(c) () -> UInt32

    /// The runtime's reply table: the one the remote shim's REPLY frames resolve.
    let replies: CEFHostReplies
    private let lastReplyTokenFn: LastReplyTokenFn

    /// The route over the remote dylib's `cmux_remote_shim_last_reply_token` (task 018) and the reply
    /// table its attach handed to the shim's reply callback.
    init(symbol: (String) -> UnsafeMutableRawPointer?, replies: CEFHostReplies) throws(CEFShimLibrary.LoadError) {
        let name = "cmux_remote_shim_last_reply_token"
        guard let pointer = symbol(name) else { throw .missingSymbol(name) }
        lastReplyTokenFn = unsafeBitCast(pointer, to: LastReplyTokenFn.self)
        self.replies = replies
    }

    /// The route of the attached host's remote shim, over the table its REPLY frames resolve; nil in
    /// process. A remote dylib without the token entry point fails the start, as a missing shim
    /// export does.
    static func route(for library: CEFRuntimeBoot) throws(CEFRuntime.BootError) -> CEFHostReplyRoute? {
        guard case .host(let host) = library else { return nil }
        do throws(CEFShimLibrary.LoadError) {
            return try CEFHostReplyRoute(symbol: host.remote.symbol, replies: host.replies)
        } catch {
            throw .shim(error)
        }
    }

    /// The token of the op the remote shim last sent for a reply; 0 when that call sent nothing.
    func lastReplyToken() -> UInt32 {
        lastReplyTokenFn()
    }

    /// The host exited (task 091): every reply still awaited or called back for fails with `hostGone`.
    func hostGone() {
        replies.failAll(.hostGone)
    }
}

/// How the answer of an async export comes, once the call was made (``CEFRuntime/sendAsync(_:)``).
/// Consume it in the turn that sent it: ``CEFRuntime/answer(_:label:timeout:)`` or
/// ``CEFRuntime/whenAnswered(_:label:timeout:then:)``.
nonisolated enum CEFShimAnswer<Value> {
    /// In process: the call's own result.
    case now(Value)
    /// Host mode: the token of the host's REPLY, expected in the reply table.
    case later(UInt32)
    /// Nothing was sent (no shim, no host attached, or the call sent no op for a reply).
    case unsent
}

nonisolated extension CEFShimAnswer: Sendable where Value: Sendable {}

/// The token form of every async export (tasks 018 and 021): one way for both backends, so a caller
/// never reads an answer in the call's turn. `gen-chromium-host-wire.py --swift-sites` counts a
/// call made inside a closure handed to `sendAsync`, `siteCall` or `profileWrite` as done.
extension CEFRuntime {
    /// Calls an async export with the shim and returns how its answer comes: the result itself in
    /// process, the REPLY token in host mode, expected in the reply table in this turn so a REPLY
    /// that comes before the caller awaits is kept. A call that sent no op for a reply (refused
    /// before the wire, a mint or a post) leaves the remote's last token as it was: that is
    /// `.unsent`, never an earlier call's token.
    func sendAsync<Value>(_ call: (CEFShimLibrary) -> Value) -> CEFShimAnswer<Value> {
        guard let shim else { return .unsent }
        guard let hostReplies else { return .now(call(shim)) }
        let before = hostReplies.lastReplyToken()
        _ = call(shim)
        let token = hostReplies.lastReplyToken()
        guard token != 0, token != before else { return .unsent }
        hostReplies.replies.expect(token)
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
            guard let replies = hostReplies?.replies else { throw .closed }
            do throws(CEFHostReplyError) {
                return try await replies.reply(to: token, as: Value.self, label: label, timeout: timeout)
            } catch {
                if case .timedOut(let what, let limit) = error { throw .timedOut("Chromium Host \(what) (\(limit))") }
                throw .closed
            }
        }
    }

    /// Calls `then` with the answer `sent` stands for (nil: none, no host, the host gone, or no
    /// REPLY within `timeout`): in this turn in process, in the turn that delivers the host's REPLY
    /// in host mode. For a caller in a synchronous turn; it awaits nothing.
    func whenAnswered<Value: CEFHostReplyValue>(_ sent: CEFShimAnswer<Value>, label: String,
                                                timeout: Duration = CEFRuntime.siteReplyTimeout,
                                                then: @escaping (Value?) -> Void) {
        switch sent {
        case .now(let value):
            then(value)
        case .unsent:
            then(nil)
        case .later(let token):
            guard let replies = hostReplies?.replies else { return then(nil) }
            replies.onReply(token, label: label, timeout: timeout) { [logger] reply in
                if case .failure(let error) = reply {
                    logger.notice("Chromium Host \(label, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                then(try? Self.decode(reply.get()))
            }
        }
    }

    /// The host exited (task 091 calls this in the exit turn): every reply still awaited or called
    /// back for fails with `hostGone`, and every profile proxy is handed to the next host again
    /// before a page of its profile opens. A host's verdict on a proxy says nothing about the host
    /// after it, whose Chromium context starts without the proxy (#24432 fails closed).
    func hostGone() {
        hostReplies?.hostGone()
        profileProxyChecks.removeAll()
        unappliedProfileProxies.formUnion(profileProxies.keys)
    }

    /// One value from a REPLY body: the op's result and nothing after it.
    private static func decode<Value: CEFHostReplyValue>(_ body: [UInt8]) throws(CEFHostReplyError) -> Value {
        var fields = try CEFHostReplyFields(encoded: body)
        let value = try Value(reply: &fields)
        try fields.finish()
        return value
    }
}
