import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// One helper conversation at a time on this Mac: a Fix and Stop Serving's
/// reverts take turns, in arrival order, so an apply can never land after
/// the revert that should undo it. The holder runs in its caller's task, so
/// a cancelled fix sees its own cancellation.
@MainActor
final class ServerFixGate {
    static let shared = ServerFixGate()

    private var busy = false
    private var waiters: [OnceContinuation<Void, OnceContinuationError>] = []

    /// Waits for the gate. Pair each call with one `release()`.
    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        // Only `release()` resumes a waiter: the gate cannot go away while this call holds it.
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in waiters.append(waiter) }
    }

    /// Hands the gate to the next waiter, or opens it.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume(returning: ())
        }
    }
}
