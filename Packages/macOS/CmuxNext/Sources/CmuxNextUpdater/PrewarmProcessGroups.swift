import Darwin
import Foundation
import os

/// The process groups a staged build's pre-warm started (``StagedUpdatePrewarm``, one group per run). A stop before
/// Sparkle moves or removes the staged copy (``UpdaterService/stopPrewarm(_:)``) kills every group and returns only
/// once each group's leader has exited, so no pre-warm process still loads from the folder (cmux#63767). A run's SIGTERM and
/// its 2 s grace before SIGKILL let a process that shuts down slowly on SIGTERM (Chromium's browser process) run on
/// while the installer removed its files; a pre-warm has nothing to save, so the stop does not wait for a grace.
nonisolated final class PrewarmProcessGroups: Sendable {
    /// What the stop measured: the groups it killed, how long their leaders took to exit, and how many groups still
    /// had a member (killed, not yet reaped) when it returned.
    struct Ended: Equatable, Sendable {
        let groups: Int
        let waited: Duration
        let stillRunning: Int
    }

    // The launch callback is synchronous (AsyncProcess's onLaunch, on the spawning thread) and the stop reads the set
    // once: a tiny set behind a lock, not an actor (the lock carve-out for synchronous callbacks).
    private let state = OSAllocatedUnfairLock(initialState: (groups: Set<pid_t>(), closed: false))

    init() {}

    /// A run started as process `pid`, the leader of its own group (``ProcessRequest/TerminationScope/processGroup``).
    /// One that starts after the stop is killed at once.
    func launched(_ pid: pid_t) {
        let closed = state.withLock { state -> Bool in
            if !state.closed { state.groups.insert(pid) }
            return state.closed
        }
        if closed { _ = Darwin.kill(-pid, SIGKILL) }
    }

    /// Kills every group the pre-warm started and waits until each group's leader has exited, at most `bound`; then
    /// counts the groups that still have a member. Nil when no group was started.
    ///
    /// SIGKILL reaches every member of a group at once (`kill(-group, SIGKILL)`), and a process with SIGKILL pending
    /// runs no further user code, so none loads from the staged copy after this; the wait is for the kernel to end
    /// them. The leaders are this process's own children; the members are never listed (cmux NEXT scans no
    /// processes): `kill(-group, 0)` only says whether a group still has one.
    func killAndWait(bound: Duration) -> Ended? {
        let groups = state.withLock { state -> Set<pid_t> in
            state.closed = true
            defer { state.groups = [] }
            return state.groups
        }
        guard !groups.isEmpty else { return nil }
        let started = ContinuousClock.now
        for group in groups { _ = Darwin.kill(-group, SIGKILL) }
        let queue = kqueue()
        guard queue >= 0 else { return Ended(groups: groups.count, waited: .zero, stillRunning: Self.alive(groups)) }
        defer { close(queue) }
        var running = Set<pid_t>()
        for leader in groups {
            var change = kevent(ident: UInt(leader), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                                fflags: NOTE_EXIT, data: 0, udata: nil)
            // ESRCH: it already exited (a zombie counts: it runs no code).
            if kevent(queue, &change, 1, nil, 0, nil) == 0 { running.insert(leader) }
        }
        let deadline = started + bound
        while !running.isEmpty {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { break }
            let (seconds, attoseconds) = left.components
            var timeout = timespec(tv_sec: Int(seconds), tv_nsec: Int(attoseconds / 1_000_000_000))
            var event = kevent()
            // concurrency-allow: a stop before Sparkle removes the staged copy waits for SIGKILLed processes to exit,
            // a few ms (measured in StagedUpdatePrewarmRealStopTests), bounded by `bound`.
            let count = kevent(queue, nil, 0, &event, 1, &timeout)
            if count > 0 { running.remove(pid_t(event.ident)) } else if count == 0 { break }
        }
        return Ended(groups: groups.count, waited: ContinuousClock.now - started, stillRunning: Self.alive(groups))
    }

    /// How many of `groups` still have a member that is not yet reaped.
    private static func alive(_ groups: Set<pid_t>) -> Int {
        groups.count { Darwin.kill(-$0, 0) == 0 || errno == EPERM }
    }
}
