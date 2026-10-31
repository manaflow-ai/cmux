import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The one order in which cmux's calls reach one browser in Chromium: each browser's calls in the order they were
/// made, while a large call's parameters are encoded off the main actor.
///
/// A call's parameters can be megabytes (the agent chat page's transport frames reach it as one `Runtime.evaluate`
/// script, `ChromiumPageHostBridge`); encoding one such script took 566 ms of the main thread (hang report v229,
/// 2026-10-30). Chrome builds and parses large JSON off its UI thread (services/data_decoder/public/cpp/
/// data_decoder.h), and its UI thread only posts the message. Here every call to a browser takes its place in that
/// browser's line in the caller's turn, and posts once every call before it posted, so no call overtakes an earlier
/// one, as when each was sent in its caller's turn:
///
/// - An awaited DevTools call (``send(_:params:post:)``) encodes its parameters on the cooperative pool
///   (``CEFDevToolsResult/encodedParams(_:)``) and posts in a main-actor turn of its own, so its caller registers
///   the wait for the result in the turn it posts (``CEFRuntime/result(of:method:timeout:)``).
/// - A one-way call (``post(_:_:)``: a freeze, a visibility change, `CEFTab.perform`) runs now, in the caller's turn,
///   when nothing of its browser waits; else right after the call ahead of it posts, in that turn.
/// - A one-way call whose answer is awaited (a page picture, ``CEFRuntime/sendDevToolsInOrder(_:method:params:timeout:refused:mayPost:)``)
///   takes a ``Ticket`` and posts in its own turn (``turn(_:)``), after checking again that it may.
///
/// A freeze made while a batch of chat frames encodes therefore reaches Chromium after the batch, not before it,
/// where the batch's script would run on a frozen page. A large call holds back only the later calls of its own
/// browser, by its encoding time; other browsers do not wait.
@MainActor
final class CEFDevToolsSendOrder {
    /// One call's place in its browser's line.
    final class Ticket {
        /// Set while it waits, ready to post, for the calls before it.
        fileprivate var waiter: OnceContinuation<Void, OnceContinuationError>?
        /// A one-way call: runs in the turn the call before it posts.
        fileprivate var op: (@MainActor () -> Bool)?

        fileprivate init(op: (@MainActor () -> Bool)? = nil) {
            self.op = op
        }
    }

    /// The calls of each browser that did not post yet, oldest first.
    private var lines: [Int32: [Ticket]] = [:]

    /// The calls of `browser` that did not post yet (tests: a call is still encoding).
    func waiting(_ browser: Int32) -> Int { lines[browser]?.count ?? 0 }

    /// Encodes `params` off the main actor, waits until every earlier call of `browser` posted, then runs `post`
    /// with the parameters' JSON text, in this call's own turn, and returns what it returned.
    ///
    /// - Parameters:
    ///   - browser: The browser the call goes to.
    ///   - params: The method's parameters (JSON values).
    ///   - post: Sends the call to Chromium (``CEFRuntime/sendDevTools(_:method:encodedParams:)``).
    /// - Returns: What `post` returned.
    func send(_ browser: Int32, params: [String: any Sendable], post: (String) -> CEFDevToolsSend?) async -> CEFDevToolsSend? {
        let ticket = take(browser)
        let text = await CEFDevToolsResult.encodedParams(params)
        await turn(ticket, of: browser)
        let sent = post(text)
        leave(ticket, of: browser)
        return sent
    }

    /// Runs `op`, a one-way call to `browser`, in the browser's order: now, in this turn, when no earlier call of
    /// `browser` waits; else in the turn the last earlier call posts, right after it.
    ///
    /// - Parameter op: Sends the call; returns false when Chromium refused it (the page is gone).
    /// - Returns: What `op` returned when it ran now; true when it waits its turn (its own answer is then dropped).
    @discardableResult
    func post(_ browser: Int32, _ op: @escaping @MainActor () -> Bool) -> Bool {
        guard lines[browser]?.isEmpty == false else { return op() }
        lines[browser, default: []].append(Ticket(op: op))
        return true
    }

    /// A place in `browser`'s line for a call that posts in its own turn (``turn(_:of:)``, then ``leave(_:of:)``).
    func take(_ browser: Int32) -> Ticket {
        let ticket = Ticket()
        lines[browser, default: []].append(ticket)
        return ticket
    }

    /// Whether `ticket` heads `browser`'s line: it may post now, in this turn.
    func heads(_ ticket: Ticket, of browser: Int32) -> Bool { lines[browser]?.first === ticket }

    /// Returns, in a turn of its own, once every call before `ticket` posted.
    func turn(_ ticket: Ticket, of browser: Int32) async {
        guard !heads(ticket, of: browser) else { return }
        // Nothing drops it: the ticket stays in its line until the call before it hands over its turn.
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in ticket.waiter = waiter }
    }

    /// Removes the head of `browser`'s line (the line itself once it is empty).
    private func dropHead(of browser: Int32) {
        guard var line = lines.removeValue(forKey: browser), !line.isEmpty else { return }
        line.removeSubrange(..<1)
        if !line.isEmpty { lines[browser] = line }
    }

    /// `ticket`, the head of `browser`'s line, posted: the one-way calls after it run now, in order, and the next
    /// call that posts in its own turn is woken (one not waiting yet posts when it reaches ``turn(_:of:)``).
    func leave(_ ticket: Ticket, of browser: Int32) {
        guard heads(ticket, of: browser) else { return }
        dropHead(of: browser)
        while let next = lines[browser]?.first {
            if let op = next.op {
                // It stays at the head while it runs: a call it makes to this browser queues behind it.
                next.op = nil
                _ = op()
                dropHead(of: browser)
                continue
            }
            if let waiter = next.waiter {
                next.waiter = nil
                waiter.resume(returning: ())
            }
            break
        }
        if lines[browser]?.isEmpty == true { lines[browser] = nil }
    }
}
