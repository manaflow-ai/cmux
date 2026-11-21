/// The one order in which cmux's DevTools calls and freezes reach one browser: the order they were made, also
/// while a large call's parameters are encoded off the main actor.
///
/// A call's parameters can be megabytes: an app page's pushes and replies reach it as one `Runtime.evaluate`
/// script (`ChromiumPageHostBridge`), and an agent's script is as large as the agent makes it. Encoding one such
/// script on the main thread took 566 ms and 1,563 ms (Lawrence's v2.2.9 and v2.2.10 hang records, 2026-10-30).
/// Chrome builds and parses large JSON off its UI thread (services/data_decoder/public/cpp/data_decoder.h); its UI
/// thread only posts the message. Here a large call takes its place in its browser's line in the caller's turn,
/// encodes on the cooperative pool, and sends in a main-actor turn of its own once every call before it was sent.
/// A small call made while the line is empty is sent in the caller's turn, as before; one made behind a waiting
/// call waits its turn. So no call overtakes an earlier one, and a large call holds back only the later calls of
/// its own browser, by its encoding time.
///
/// ```swift
/// let ticket = order.take(browser)
/// let text = await CEFDevToolsResult.encodedParams(params)
/// await order.turn(ticket, of: browser)
/// send(text)
/// order.leave(ticket, of: browser)
/// ```
@MainActor
final class CEFDevToolsCallOrder {
    /// One call's place in its browser's line.
    final class Ticket {
        /// Set while the call waits, ready to send, for the calls before it.
        fileprivate var waiter: CheckedContinuation<Void, Never>?
        /// A one-way call (``post(_:_:)``): it runs in the turn the call before it leaves.
        fileprivate var op: (@MainActor () -> Bool)?

        fileprivate init(op: (@MainActor () -> Bool)? = nil) {
            self.op = op
        }
    }

    /// The calls of each browser that were not sent yet, oldest first.
    private var lines: [Int32: [Ticket]] = [:]

    /// True when no call of `browser` waits: a call made now may be sent in this turn.
    func isIdle(_ browser: Int32) -> Bool { lines[browser]?.isEmpty ?? true }

    /// The calls of `browser` that were not sent yet (tests: a call still encodes).
    func waiting(_ browser: Int32) -> Int { lines[browser]?.count ?? 0 }

    /// A place at the end of `browser`'s line, for a call that sends in its own turn (``turn(_:of:)``, then
    /// ``leave(_:of:)``). Every ticket taken must leave, or the calls after it never go.
    func take(_ browser: Int32) -> Ticket {
        let ticket = Ticket()
        lines[browser, default: []].append(ticket)
        return ticket
    }

    /// Returns once every call before `ticket` was sent: at once when it heads its line, else in the turn the call
    /// before it leaves.
    func turn(_ ticket: Ticket, of browser: Int32) async {
        guard lines[browser]?.first !== ticket else { return }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in ticket.waiter = waiter }
    }

    /// Runs `op`, a one-way call to `browser` (a freeze): now, in this turn, when no call of `browser` waits;
    /// else in the turn the last call before it leaves, right after that call.
    ///
    /// - Parameter op: Sends the call; returns false when Chromium refused it (the page is gone or still visible).
    /// - Returns: What `op` returned when it ran now; true when it waits its turn.
    @discardableResult
    func post(_ browser: Int32, _ op: @escaping @MainActor () -> Bool) -> Bool {
        guard !isIdle(browser) else { return op() }
        lines[browser, default: []].append(Ticket(op: op))
        return true
    }

    /// `ticket`, the head of `browser`'s line, was sent: the one-way calls right after it run now, in order, and
    /// the next call that sends in its own turn is woken (one still encoding goes when it reaches ``turn(_:of:)``).
    func leave(_ ticket: Ticket, of browser: Int32) {
        guard lines[browser]?.first === ticket else { return }
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
                waiter.resume()
            }
            break
        }
    }

    private func dropHead(of browser: Int32) {
        guard let line = lines.removeValue(forKey: browser) else { return }
        let rest = line.dropFirst()
        if !rest.isEmpty { lines[browser] = Array(rest) }
    }
}
