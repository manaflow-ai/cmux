import AppKit
import CmuxNextInputCore
import CmuxNextWakeups

/// The slots of one window waiting for their presented estimate, in the order ``InputLatencyTracker`` asked
/// `PresentationClock` for it. The clock resolves one window's commits first in, first out (they queue on that
/// window's hold until its next tick), so the queue's oldest token is the one each estimate belongs to.
///
/// The resolve closure is built once per window and the tokens sit in a fixed ring (the slot table's capacity: each
/// open slot is in at most one queue), so asking for an estimate allocates nothing.
@MainActor
final class InputPresentedQueue {
    /// Takes one slot's estimate (or nil when the window went away before it resolved).
    typealias Deliver = @MainActor (InputLatencyToken, PresentedEstimate?) -> Void

    /// The window the queue serves; nil for the window-less app scheduler (``isApp``).
    private(set) weak var window: NSWindow?
    let isApp: Bool
    private let deliver: Deliver
    private var tokens: ContiguousArray<InputLatencyToken>
    private var head = 0
    private(set) var count = 0

    /// Passed to `PresentationClock.presented(commitEndNanos:window:_:)` for every slot of this window.
    private(set) lazy var resolve: PresentationClock.Resolve = { [weak self] estimate in self?.resolved(estimate) }

    init(window: NSWindow?, capacity: Int, deliver: @escaping Deliver) {
        self.window = window
        isApp = window == nil
        self.deliver = deliver
        tokens = ContiguousArray(repeating: InputLatencyToken(rawValue: 0), count: max(capacity, 1))
    }

    /// Whether this queue serves `window`'s slots.
    func serves(_ window: NSWindow?) -> Bool {
        guard let window else { return isApp }
        return self.window === window
    }

    /// The queue's window closed: it can never be asked again.
    var isAbandoned: Bool { !isApp && window == nil }

    /// Adds `token` before asking the clock for its estimate (the clock may resolve before it returns).
    func enqueue(_ token: InputLatencyToken) {
        guard count < tokens.count else {
            // Unreachable while every queued token is an open slot of the table this queue was sized for.
            deliver(token, nil)
            return
        }
        tokens[(head + count) % tokens.count] = token
        count += 1
    }

    /// Delivers every waiting slot with no estimate (its window closed before its frame resolved).
    func abandon() {
        while count > 0 { deliver(dequeue(), nil) }
    }

    private func resolved(_ estimate: PresentedEstimate) {
        guard count > 0 else { return }
        deliver(dequeue(), estimate)
    }

    private func dequeue() -> InputLatencyToken {
        let token = tokens[head]
        head = (head + 1) % tokens.count
        count -= 1
        return token
    }
}
