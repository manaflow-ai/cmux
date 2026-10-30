import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The order in which a runtime's awaited DevTools calls reach Chromium: each browser's in the order they were made,
/// while their parameters are encoded off the main actor.
///
/// A call's parameters can be megabytes (the agent chat page's transport frames reach it as one `Runtime.evaluate`
/// script, `ChromiumPageHostBridge`); encoding one such script took 566 ms of the main thread (hang report v229,
/// 2026-10-30). Chrome builds and parses large JSON off its UI thread (services/data_decoder/public/cpp/
/// data_decoder.h), and its UI thread only posts the message. Here a call takes its place in its browser's line in
/// the caller's turn (``send(_:params:post:)``), its parameters are encoded on the cooperative pool
/// (``CEFDevToolsResult/encodedParams(_:)``), and it posts in a main-actor turn of its own once every call before it
/// in that line was posted. The order Chromium sees is the order of the calls, as when each was sent in its caller's
/// turn: a page host's reply sent after a large script still reaches the page after it. A large call holds back only
/// the later calls of its own browser, by its encoding time.
///
/// The order holds among these awaited calls only. A one-way send (``CEFRuntime/sendDevTools(_:method:params:)``: a
/// freeze, a page picture, `CEFTab.perform`) still leaves in its caller's turn and can reach Chromium before an
/// awaited call that is still encoding; it never had an order with the other pipes (`tabSetFrozen`, the page push).
/// A caller that checks a condition (the page lives, the quit did not begin) and needs the call to leave in that same
/// turn sends one-way and awaits ``CEFRuntime/result(of:method:timeout:)``, as `CEFFullPageCapture` does.
///
/// A call posts in its own turn, not in the turn of the call before it, so its caller can wait for the result in the
/// same turn it posted (``CEFRuntime/result(of:method:timeout:)``): an answer that comes in a later turn always finds
/// its waiter.
@MainActor
final class CEFDevToolsSendOrder {
    /// One call's place in its browser's line.
    private final class Place {
        /// Its parameters are encoded: it posts as soon as it heads the line.
        var encoded = false
        /// Set while it waits, encoded, for the calls before it.
        var waiter: OnceContinuation<Void, OnceContinuationError>?
    }

    /// The calls of each browser that did not post yet, oldest first.
    private var lines: [Int32: [Place]] = [:]

    /// Encodes `params` off the main actor, waits until every earlier call of `browser` posted, then runs `post`
    /// with the parameters' JSON text, in this call's own turn, and returns what it returned.
    ///
    /// - Parameters:
    ///   - browser: The browser the call goes to.
    ///   - params: The method's parameters (JSON values).
    ///   - post: Sends the call to Chromium (``CEFRuntime/sendDevTools(_:method:encodedParams:)``).
    /// - Returns: What `post` returned.
    func send(_ browser: Int32, params: [String: any Sendable], post: (String) -> CEFDevToolsSend?) async -> CEFDevToolsSend? {
        let place = Place()
        lines[browser, default: []].append(place)
        let text = await CEFDevToolsResult.encodedParams(params)
        place.encoded = true
        if lines[browser]?.first !== place {
            // Nothing drops it: the place stays in its line until the call before it hands over its turn.
            _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in place.waiter = waiter }
        }
        let sent = post(text)
        leave(browser)
        return sent
    }

    /// The calls of `browser` that did not post yet (tests: a call is still encoding).
    func waiting(_ browser: Int32) -> Int { lines[browser]?.count ?? 0 }

    /// The head of `browser`'s line posted: the next call posts now if it is encoded, else when its encoding ends.
    private func leave(_ browser: Int32) {
        guard var line = lines[browser], !line.isEmpty else { return }
        line.removeFirst()
        guard let next = line.first else {
            lines[browser] = nil
            return
        }
        lines[browser] = line
        guard next.encoded, let waiter = next.waiter else { return }
        next.waiter = nil
        waiter.resume(returning: ())
    }
}
