import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Who holds each `carrier serve` socket path in this process: the last serve child spawned for it, until that
/// child exits. A session replaced for the same machine (``CloudService`` drops every session on a team switch,
/// sign-out or a policy flip and makes new ones) makes a new ``CloudCarrierServe`` for the same socket while the
/// old one's child is still exiting; the new one waits here for that exit instead of reading the old child's
/// claim as another cmux serving the machine. The wait is bounded (``CloudCarrierServe/leaseWait``): past it the
/// new child starts anyway and serve's own refusal (exit 64, ``CloudCarrierDial/socketTaken``) says why. The app's
/// one registry is its ``CloudCarrierStreams``' (``CloudService`` makes every session's connector with the same one).
final class CloudCarrierLeases: Sendable {
    private struct Holder {
        let owner: UInt64
        let exited: Task<Void, Never>
    }

    private struct State {
        var lastOwner: UInt64 = 0
        var holders: [String: Holder] = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// A new serve instance's id.
    func newOwner() -> UInt64 {
        state.withLock { state in
            state.lastOwner &+= 1
            return state.lastOwner
        }
    }

    /// `child` of `owner` holds `path` until it exits.
    func hold(_ path: String, by owner: UInt64, child: ChildProcess) {
        // task-owner: ends when the child exits (every serve child exits once its stdin closes, or at SIGTERM)
        let exited = Task { _ = await child.waitForExit() }
        state.withLock { $0.holders[path] = Holder(owner: owner, exited: exited) }
    }

    /// The exit another owner's child holds `path` until; nil when no other owner's child holds it.
    func holder(of path: String, besides owner: UInt64) -> Task<Void, Never>? {
        state.withLock { state in
            guard let holder = state.holders[path], holder.owner != owner else { return nil }
            return holder.exited
        }
    }

    /// Returns once no other owner's child holds `path`, or after `bound`.
    func released(_ path: String, besides owner: UInt64, atMost bound: Duration) async {
        guard let exited = holder(of: path, besides: owner) else { return }
        let once = Once()
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            once.set(waiter)
            // task-owner: ends when the holder's child exits, which its own serve's stop deadline bounds
            Task { await exited.value; once.resume() }
            once.timer.schedule(after: bound) { once.resume() }
        }
    }

    /// Resumes one waiter once, from whichever of the exit and the bound comes first.
    private final class Once: Sendable {
        let timer = DemandTimer(owner: "CloudCarrierLeases.wait")
        private let waiter = Mutex<CheckedContinuation<Void, Never>?>(nil)

        func set(_ waiter: CheckedContinuation<Void, Never>) { self.waiter.withLock { $0 = waiter } }

        func resume() {
            let waiter = waiter.withLock { waiter in
                defer { waiter = nil }
                return waiter
            }
            timer.cancel()
            waiter?.resume()
        }
    }
}
