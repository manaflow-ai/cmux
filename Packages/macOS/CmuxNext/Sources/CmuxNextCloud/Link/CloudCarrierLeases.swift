import CmuxNextCompat
import CmuxNextWakeups
import Foundation

/// Who holds each `carrier serve` socket path across serve instances: one owner at a time, from its claim (a
/// launch reading its token) through its child's exit. A session replaced for the same machine (``CloudService``
/// drops every session on a team switch, sign-out or a policy flip and makes new ones) makes a new
/// ``CloudCarrierServe`` for the same socket while the old one's child is still exiting; the new one waits here for
/// that exit instead of reading the old child's claim as another cmux serving the machine, and two new ones never
/// both launch. The wait is bounded (``CloudCarrierServe/leaseWait``): past it the claim is taken anyway and serve's
/// own refusal (exit 64, ``CloudCarrierDial/socketTaken``) says why. The app's one registry is its
/// ``CloudCarrierStreams``' (``CloudService`` makes every session's connector with the same one).
final class CloudCarrierLeases: Sendable {
    private struct Holder {
        let owner: UInt64
        /// Tells this hold from a later one of the same path.
        let token: UInt64
        /// A child holds it (until its exit), else a launch that has not spawned yet.
        let child: Bool
    }

    private struct State {
        var last: UInt64 = 0
        var holders: [String: Holder] = [:]
        var waiting: [String: [Once]] = [:]
    }

    private let state = Mutex(State())

    init() {}

    /// A new serve instance's id.
    func newOwner() -> UInt64 {
        state.withLock { state in
            state.last &+= 1
            return state.last
        }
    }

    /// Takes `path` for `owner`'s launch when no other owner holds it, or anyway with `force`; true when
    /// `owner` holds it now. A launch that then spawns nothing gives it back (``release(_:by:)``).
    func claim(_ path: String, by owner: UInt64, force: Bool = false) -> Bool {
        state.withLock { state in
            if let holder = state.holders[path], holder.owner != owner, !force { return false }
            state.last &+= 1
            state.holders[path] = Holder(owner: owner, token: state.last, child: false)
            return true
        }
    }

    /// `child` of `owner` holds `path` until it exits.
    func hold(_ path: String, by owner: UInt64, child: ChildProcess) {
        let token = state.withLock { state in
            state.last &+= 1
            state.holders[path] = Holder(owner: owner, token: state.last, child: true)
            return state.last
        }
        // task-owner: ends when the child exits (every serve child exits once its stdin closes, or at SIGTERM)
        Task {
            _ = await child.waitForExit()
            self.remove(path) { $0.token == token }
        }
    }

    /// Gives back `owner`'s claim of `path` that no child took over.
    func release(_ path: String, by owner: UInt64) {
        remove(path) { $0.owner == owner && !$0.child }
    }

    /// Returns once `path` changed hands (another owner gave it up), or at `deadline`; at once when no other
    /// owner holds it. The caller claims again after.
    func released(_ path: String, besides owner: UInt64, until deadline: ContinuousClock.Instant) async {
        let left = ContinuousClock.now.duration(to: deadline)
        guard left > .zero else { return }
        let once = Once()
        let held = state.withLock { state in
            guard let holder = state.holders[path], holder.owner != owner else { return false }
            state.waiting[path, default: []].append(once)
            return true
        }
        guard held else { return }
        once.timer.schedule(after: left) { once.resume() }
        await withCheckedContinuation { once.set($0) }
    }

    private func remove(_ path: String, if matches: (Holder) -> Bool) {
        let waiting: [Once] = state.withLock { state in
            guard let holder = state.holders[path], matches(holder) else { return [] }
            state.holders[path] = nil
            return state.waiting.removeValue(forKey: path) ?? []
        }
        for once in waiting { once.resume() }
    }

    /// Resumes one waiter once, from whichever of the hand-over and the deadline comes first (either may come
    /// before the waiter is set).
    private final class Once: Sendable {
        private enum Phase {
            case pending
            case waiting(CheckedContinuation<Void, Never>)
            case fired
        }

        let timer = DemandTimer(owner: "CloudCarrierLeases.wait")
        private let phase = Mutex(Phase.pending)

        func set(_ waiter: CheckedContinuation<Void, Never>) {
            let fired = phase.withLock { phase in
                if case .fired = phase { return true }
                phase = .waiting(waiter)
                return false
            }
            if fired { waiter.resume() }
        }

        func resume() {
            let waiter: CheckedContinuation<Void, Never>? = phase.withLock { phase in
                defer { phase = .fired }
                if case .waiting(let waiter) = phase { return waiter }
                return nil
            }
            timer.cancel()
            waiter?.resume()
        }
    }
}
