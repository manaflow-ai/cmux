import Foundation

/// One helper conversation at a time on this Mac: a Fix and Stop Serving's
/// reverts take turns, in arrival order, so an apply can never land after
/// the revert that should undo it. The holder runs in its caller's task, so
/// a cancelled fix sees its own cancellation.
@MainActor
final class ServerFixGate {
    static let shared = ServerFixGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits for the gate. Pair each call with one `release()`.
    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the gate to the next waiter, or opens it.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
