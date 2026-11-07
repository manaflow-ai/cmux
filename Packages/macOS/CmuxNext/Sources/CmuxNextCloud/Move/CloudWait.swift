import CmuxNextCompat
import CmuxNextDaemon
import Foundation
public import CmuxNextWakeups

/// Bounded waits on main-actor state for the Cloud flows.
@MainActor
public struct CloudWait {
    public init() {}
    /// Whether `condition` holds within `limit`: an observation, bounded by a one-shot deadline.
    public static func holds(within limit: Duration, until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        await holds(within: limit, clock: ContinuousClock(), until: condition)
    }

    /// ``holds(within:until:)`` with its deadline on `clock` (a test's ``ManualClock``).
    public static func holds<C: Clock & Sendable>(within limit: Duration, clock: C,
                                                  until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool where C.Duration == Duration {
        if condition() { return true }
        // concurrency-allow: the observation task exits on cancellation; this bounds a machine link's start
        return await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await observe(condition) }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine link to come up
                try? await clock.sleep(for: limit)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    /// How a start's wait spaces its redials (``holds(within:redialing:redial:until:)``): 1 s growing to 10 s, so a
    /// new machine's receiver that answers half a minute after its record runs is dialed again within seconds.
    public static let startRedial = Backoff(initial: .seconds(1), maximum: .seconds(10))

    /// Whether `condition` holds within `limit`: `redial` runs first and again after each of `backoff`'s delays,
    /// so a link that ended while the condition did not hold yet is dialed again (a new machine's daemon may
    /// answer a little after its record runs). Never past `limit`, and never without a delay between redials.
    public static func holds(within limit: Duration, redialing backoff: Backoff, redial: @MainActor () -> Void,
                             until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        await holds(within: limit, redialing: backoff, clock: ContinuousClock(), redial: redial, until: condition)
    }

    /// ``holds(within:redialing:redial:until:)`` with its deadline and delays on `clock` (a test's ``ManualClock``).
    public static func holds<C: Clock & Sendable>(within limit: Duration, redialing backoff: Backoff, clock: C, redial: @MainActor () -> Void,
                                                  until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool where C.Duration == Duration {
        let deadline = clock.now.advanced(by: limit)
        var backoff = backoff
        // wakeup-allow: each pass waits one backoff delay (at least its initial's floor) and ends at the deadline
        while !Task.isCancelled {
            let left = clock.now.duration(to: deadline)
            guard left > .zero else { break }
            redial()
            if await holds(within: min(backoff.next(), left), clock: clock, until: condition) { return true }
        }
        // The deadline passed or the wait was cancelled: a change racing either is not this wait's answer.
        return false
    }

    /// The async-redial form is used when each bounded observation must reconcile remote state
    /// before checking the condition (for example, a machine created by a just-completed fork).
    public static func holds(tries: Int, each: Duration,
                             redial: @escaping @MainActor @Sendable () async -> Void,
                             until condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        var up = false
        for _ in 0..<tries where !up {
            await redial()
            up = await holds(within: each, until: condition)
        }
        return up
    }

    /// Waits within `limit` for a link to come up: nil once `connected`, else `failure`, or `deadline`
    /// when there is none. A failure already showing when the wait begins is the last link's: it ends
    /// the wait only once the new connect cleared it and failed again, or at the deadline.
    public static func linkFailure(within limit: Duration, connected: @escaping @MainActor @Sendable () -> Bool,
                                   failure: @escaping @MainActor @Sendable () -> String?, deadline: String) async -> String? {
        @MainActor final class Seen { var cleared = false }
        let seen = Seen()
        seen.cleared = failure() == nil
        _ = await holds(within: limit) {
            if connected() { return true }
            guard failure() != nil else {
                seen.cleared = true
                return false
            }
            return seen.cleared
        }
        return connected() ? nil : failure() ?? deadline
    }

    private static func observe(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        for await ready in ObservationStream({ condition() }) where ready { return true }
        return false
    }
}

extension CloudWait {
    /// Waits while `status` reads `starting` (the machine's Resume Machine runs, from this Mac or another), up to
    /// `limit`: a start or attach waits out a resume instead of refusing it. `read` reads the record again, at
    /// once and then after each of ``startRedial``'s delays, so a resume this Mac did not send is seen too.
    /// Returns at once for any other status.
    public static func outwaitResume(of status: @escaping @MainActor @Sendable () -> CloudMachine.Status, within limit: Duration,
                                     read: @escaping @MainActor @Sendable () async -> Void) async {
        guard status() == .starting else { return }
        _ = await holds(within: limit, redialing: startRedial, redial: {
            // task-owner: one record read; the wait observes what it applies and ends at its own deadline
            Task { @MainActor in await read() }
        }) { status() != .starting }
    }

    /// Whether `wait` answered true within `limit`; true too when it ran past `limit`, since what it waits on
    /// may still run. False only when `wait` answered false (nothing to wait on).
    public static func ended(within limit: Duration, _ wait: @escaping @Sendable () async -> Bool) async -> Bool {
        // concurrency-allow: `wait` exits on cancellation; this bounds a start's wait on its machine's update
        await withTaskGroup(of: Bool?.self) { group -> Bool in
            group.addTask { await wait() }
            group.addTask {
                // wakeup-allow: one-shot deadline for a machine update a start waits on
                try? await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next().flatMap { $0 } ?? true
        }
    }

    /// A start's link wait: `linkUp` once and, when `updating` waited out an update of the machine that ran
    /// meanwhile (it restarts the daemon the link reached), once more, so the agent starts on the new daemon.
    public static func linked(within limit: Duration, _ linkUp: () async -> Bool,
                              updating: @escaping @Sendable () async -> Bool) async -> Bool {
        let up = await linkUp()
        guard up, await ended(within: limit, updating) else { return up }
        return await linkUp()
    }

    /// A start's link wait that holds only when `held` (a live daemon and no failed resume) does after it; when not, and
    /// `redialable` says the link's last end is one another dial can help, `again` dials and the wait runs once more. A
    /// just-resumed machine's tunnel peer may not answer the first dials (prod, 2026-11-05: "no handshake within 5 s",
    /// then "the tunnel peer setup failed: no route to this host", state running), and the start failed at 59 s.
    ///
    /// Not a second copy of `linkUp`'s own redial (``holds(within:redialing:clock:redial:until:)``), which dials only an
    /// app link that ended on a running machine and stops at its deadline. This one dials as the person's Retry does,
    /// with no app link or on a machine not yet shown running; it catches a link that came up but dropped before the
    /// start read it (`held`); and it gives that dial a wait of its own. Nothing in Rust waits on the Mac's link
    /// (cmux-tui serving proves its daemon up, not this Mac's socket to it). `redialable` must also check that the
    /// start's account is still the one signed in, since `again` may resume the machine.
    public static func linkedAgain(_ wait: () async -> Bool, held: () -> Bool, redialable: () -> Bool,
                                   again: () -> Void) async -> Bool {
        if await wait(), held() { return true }
        guard redialable(), !Task.isCancelled else { return false }
        again()
        return await wait() && held()
    }

    /// `start`, tried once more when its first try failed on a connection that closed (`closed`), once `relink`
    /// says the link is back: a just-resumed machine's link can drop once under a start (prod, 2026-11-05: "started
    /// but its agent didn't (cmux-tui connection closed: EOF)"). Any other failure, a second one, or a link that
    /// does not come back throws as it is.
    /// Whether a start's failure is its link dropping under it, which a relink and one more try can help (``retriedOnce``'s
    /// `closed`): the connection closed (an EOF right after a resume), or the link socket was gone or refused while its
    /// carrier rebound it (`connect …/cmux-link-….sock failed: No such file or directory`, start matrix run 42125025387).
    public nonisolated static func linkDropped(_ error: any Error) -> Bool {
        switch error {
        case DaemonError.connectionClosed: true
        case DaemonError.connectFailed(_, let code): code == ENOENT || code == ECONNREFUSED
        default: false
        }
    }

    /// A refused start's machine `update`, then its new link: the update restarts the machine's daemon and its carrier
    /// rebinds the link socket, so starting again at once dialed the socket while it was gone (start matrix run
    /// 42125025387 on bcf992a1: a first chat with no folder on a new machine). As ``CloudOutdatedMachine/copy`` does,
    /// this waits, up to `relink`, for `handshake` (the connection's key) to change from what it was before. False when
    /// `update` ran no turn; true after the wait, whether the new handshake came or not (the start's next refusal stands).
    public static func updatedThenRelinked(handshake: @escaping @MainActor @Sendable () -> String?, relink: Duration = .seconds(90),
                                           update: () async -> Bool) async -> Bool {
        let before = handshake()
        guard await update() else { return false }
        _ = await holds(within: relink) { handshake().map { $0 != before && $0 != "refused" } ?? false }
        return true
    }

    /// `attempt`, tried once more when it failed while the link dropped under it (`epoch`, the daemon store's connection
    /// epoch, moved during the try, or the link no longer `held`), once `relink` connects again. A new machine's daemon can
    /// restart under start-session's wait for its first tree (an image whose updater flips right after boot): `cmux chat
    /// --on vm:new` answered "didn't connect" 13 s after the machine came up (prod, 2026-11-07). A failure with the link
    /// still up, a cancellation, a relink that fails or a second failure throws as it is.
    public static func relinkedOnce<T>(epoch: () -> Int, held: () -> Bool, relink: () async -> Bool,
                                       _ attempt: () async throws -> T) async throws -> T {
        let before = epoch()
        return try await retriedOnce(attempt, closed: { _ in epoch() != before || !held() }, relink: relink)
    }

    public static func retriedOnce<T>(_ start: () async throws -> T, closed: (any Error) -> Bool,
                                      relink: () async -> Bool) async throws -> T {
        do {
            return try await start()
        } catch where closed(error) && !Task.isCancelled {
            guard await relink() else { throw error }
            return try await start()
        }
    }
}
