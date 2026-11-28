import CmuxNextCompat
public import CmuxNextDaemon
import CryptoKit
import Foundation
import OSLog
public import CmuxNextWakeups

/// Bounded waits on main-actor state for the Cloud flows: the observation glue. What counts as done, the
/// deadlines and which failure is a dropped link are Rust's (`moves::wait`, ops `cloud_move_*`).
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

    /// How a start's wait spaces its redials (``holds(within:redialing:redial:until:)``), as Rust's deadlines say.
    public static let startRedial = Backoff(initial: .milliseconds(CloudMoveCore.deadlines.startRedialInitialMs),
                                            maximum: .milliseconds(CloudMoveCore.deadlines.startRedialMaximumMs))

    /// One start wait's redial beats, as Rust's `start_redial` says: a paused machine resumes once, and a running
    /// machine's ended link connects again, a bounded number of times (a new machine's updater restarts its services
    /// seconds after the create, which can end the first connect).
    @MainActor public final class StartRedials {
        private var resumed = false
        private var redials = 0

        public init() {}

        /// One beat: `ended` is the app link's failure showing with no connect running.
        public func beat(ended: Bool, status: CloudMachine.Status, resume: () -> Void, connect: () -> Void) {
            struct Look: Encodable { var ended: Bool, running: Bool, paused: Bool, resumed: Bool, redials: Int }
            struct Answer: Decodable { var redial: String }
            let look = Look(ended: ended, running: status == .running, paused: status == .paused, resumed: resumed, redials: redials)
            // An FFI pinned from before the op answers nothing: the wait keeps its one resume, as before.
            switch CloudMoveCore().call("start_redial", look, as: Answer.self)?.redial ?? (look.paused && !resumed ? "resume" : nil) {
            case "resume": resumed = true; resume()
            case "connect": redials += 1; connect()
            default: break
            }
        }
    }

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
        struct Look: Encodable { var connected: Bool, failed: Bool, cleared: Bool }
        struct Step: Decodable { var done: Bool, cleared: Bool }
        let seen = Seen()
        seen.cleared = failure() == nil
        _ = await holds(within: limit) {
            let look = Look(connected: connected(), failed: failure() != nil, cleared: seen.cleared)
            guard let step = CloudMoveCore().call("link_look", look, as: Step.self) else { return look.connected }
            seen.cleared = step.cleared
            return step.done
        }
        return connected() ? nil : failure() ?? deadline
    }

    /// Waits for the app's first machine list (an app just launched loads it after sign-in) the way
    /// cmux-cloud-start-core's `list_wait` paces it, the same wait as `cmux cloud start-chat`'s: `read` reads
    /// the list, and the wait pauses until it is `loaded` or Rust's pace is up, then asks again. A list still
    /// unread when Rust ends the wait is the caller's to refuse. Only the host loop; the rule is Rust's.
    public static func firstList(loaded: @escaping @MainActor @Sendable () -> Bool, signedIn: @MainActor () -> Bool,
                                 read: @MainActor () async -> Void) async {
        if !loaded() { await read() }
        let clock = ContinuousClock(), began = clock.now
        // wakeup-allow: each pass waits Rust's pace (an observation that ends once the list loads); Rust ends it within LIST_LOAD_WAIT
        while !Task.isCancelled, case .pause(let ms, let readAfter) = CloudStartCore().listWait(
            elapsedMs: Int(began.duration(to: clock.now) / .milliseconds(1)), loaded: loaded(), signedIn: signedIn()) {
            _ = await holds(within: .milliseconds(ms), until: loaded)
            if readAfter, !loaded() { await read() }
        }
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

    /// Waits while `status` reads `pausing` (an idle pause or a Pause Machine landing), up to `limit`, as
    /// ``outwaitResume(of:within:read:)`` waits out a resume: a start that found its machine not running resumes it
    /// once it is paused, never refuses it as pausing (cmux#47638). Returns at once for any other status.
    public static func outwaitPause(of status: @escaping @MainActor @Sendable () -> CloudMachine.Status, within limit: Duration,
                                    read: @escaping @MainActor @Sendable () async -> Void) async {
        guard status() == .pausing else { return }
        _ = await holds(within: limit, redialing: startRedial, redial: {
            // task-owner: one record read; the wait observes what it applies and ends at its own deadline
            Task { @MainActor in await read() }
        }) { status() != .pausing }
    }

    /// The settle wait's line in the app log, which the probe reads (`cloud machine settle:`).
    nonisolated static let settleLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cloud")

    /// What ``settle(of:within:log:read:)`` ended on, as Rust's `cloud_move_settle` answers it.
    public enum Settled: Equatable, Sendable {
        /// The machine runs (or is paused, and the caller's attach resumes it).
        case proceed
        /// Rust refused: a delete, the deadline, or `CMUX_CLOUD_SETTLE=0` on a pause or resume in flight.
        case refused(String)
    }

    /// Waits out one machine's transient states for a caller that needs it running (a chat's start, a send, an exec,
    /// a fork), as cmux-cloud-start-core's `settle` decides each look: a pause in flight is waited out and a resume in
    /// flight too, up to `limit`, never answered as "This machine is pausing" (ask-259986a6c4, Leo 2026-11-25: "whoa
    /// what happened here"). A paused machine proceeds: the caller's attach resumes it. Logs one
    /// `cloud machine settle:` line when it waited. Only the host loop; the rule is Rust's.
    /// `waking` is told Rust's `waking` before each wait and false once the loop ends after one: the start card's
    /// "Waking machine" line.
    public static func settle(of status: @escaping @MainActor @Sendable () -> CloudMachine.Status, within limit: Duration,
                              log: ((String) -> Void)? = nil, waking: (@MainActor (Bool) -> Void)? = nil,
                              read: @escaping @MainActor @Sendable () async -> Void) async -> Settled {
        struct Look: Encodable { var status: CloudMachine.Status, waitedMs: UInt64, resumes: UInt32, limitMs: UInt64 }
        struct Act: Decodable { var act: String, reason: String?, waking: Bool? }
        let clock = ContinuousClock(), began = clock.now
        let limitMs = UInt64(max(0, limit.components.seconds)) * 1000 + UInt64(limit.components.attoseconds / 1_000_000_000_000_000)
        var waited: [String] = []
        defer {
            if !waited.isEmpty {
                waking?(false)
                let ms = began.duration(to: clock.now).components
                let line = "cloud machine settle: waited \(waited.joined(separator: ",")) \(ms.seconds * 1000 + ms.attoseconds / 1_000_000_000_000_000) ms, now \(status().rawValue)"
                if let log { log(line) } else { settleLogger.notice("\(line, privacy: .public)") }
            }
        }
        // wakeup-allow: each pass is one bounded wait on the record (outwaitPause / outwaitResume); Rust ends it at `limit`
        while !Task.isCancelled {
            let elapsed = began.duration(to: clock.now)
            let look = Look(status: status(), waitedMs: UInt64(max(0, elapsed.components.seconds)) * 1000
                                + UInt64(max(0, elapsed.components.attoseconds) / 1_000_000_000_000_000),
                            resumes: 0, limitMs: limitMs)
            // No answer from Rust: the old rule (a pause or resume in flight is the caller's to refuse).
            guard let act = CloudMoveCore().call("settle", look, as: Act.self) else { return .proceed }
            let left = max(.zero, limit - elapsed)
            if act.waking == true { waking?(true) }
            switch act.act {
            case "waitPausing":
                waited.append("pausing")
                await outwaitPause(of: status, within: left, read: read)
            case "waitStarting":
                waited.append("starting")
                await outwaitResume(of: status, within: left, read: read)
            case "refuse": return .refused(act.reason ?? "deadline")
            default: return .proceed // proceed, or resume: the caller's attach resumes a paused machine
            }
        }
        return .proceed
    }

    /// A start whose machine's exec route refused it as not running (`vm_not_running`, cmux#47638) though its link may be up:
    /// a click's link connect starts a paused machine and answers before its record runs, and an idle pause can land as the
    /// link comes up. The record is read again (`read(true)`, whatever the link says), a pause in flight is waited out, a
    /// paused machine resumes (`resume`: Resume Machine, as an attach does), and a resume in flight is waited out, each up
    /// to `limit`. The caller then connects the machine's link as before.
    public static func startStopped(status: @escaping @MainActor @Sendable () -> CloudMachine.Status, within limit: Duration,
                                    read: @escaping @MainActor @Sendable (_ force: Bool) async -> Void,
                                    resume: @MainActor () async throws -> Void) async throws {
        await read(true)
        await outwaitPause(of: status, within: limit) { await read(false) }
        if status() == .paused {
            do { try await resume() } catch where !(error is CancellationError) {
                // A resume from elsewhere (the link's own connect, another Mac) went first: the record runs or starts now.
                await read(true)
                guard status() == .starting || status() == .running else { throw error }
            }
        }
        await outwaitResume(of: status, within: limit) { await read(false) }
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

    /// `start`, tried once more when its first try failed on a connection that closed (`closed`), once `relink`
    /// says the link is back: a just-resumed machine's link can drop once under a start (prod, 2026-11-05: "started
    /// but its agent didn't (cmux-tui connection closed: EOF)"). Any other failure, a second one, or a link that
    /// does not come back throws as it is.
    /// Whether a start's failure is its link dropping under it, which a relink and one more try can help (``retriedOnce``'s
    /// `closed`): the connection closed (an EOF right after a resume), or the link socket was gone or refused while its
    /// carrier rebound it (`connect …/cmux-link-….sock failed: No such file or directory`, start matrix run 42125025387),
    /// or a fresh connection's first request got no reply (Rust `wait::link_dropped` decides from the timed-out request).
    public nonisolated static func linkDropped(_ error: any Error) -> Bool {
        struct Reply: Decodable { var dropped: Bool }
        return CloudMoveCore().call("link_dropped", StartFailure(error), as: Reply.self)?.dropped ?? false
    }

    /// Whether a start's failure says the link the app still holds is stale (Rust `wait::link_stale`): a fresh
    /// connection's first request got no reply. A relink for it drops that link and waits for a new one, since a wait
    /// for "a link is up" answers at once with the dead one (``retriedOnce(_:closed:relinkAfter:)``).
    public nonisolated static func linkStale(_ error: any Error) -> Bool {
        struct Reply: Decodable { var stale: Bool }
        return CloudMoveCore().call("link_stale", StartFailure(error), as: Reply.self)?.stale ?? false
    }

    /// A start's relink after its failure (``retriedOnce(_:closed:relinkAfter:)``). A stale link (``linkStale(_:)``: a
    /// fresh connection's first request got no reply) is still held as connected, so a wait for "a link is up" answered
    /// at once and the one more try dialed the same dead link (cosmic-gray 2026-11-27, 2 AutoCloud starts: "started but
    /// its agent didn't (timed out: identify (no progress for 10.0 s))"). That LINK is dropped (DROP, as after an update
    /// that restarted the daemon) and this waits, up to ``relinkWait``, for the connection that replaces it (or a
    /// REFUSED link) before UP, the usual wait. Any other failure: UP alone.
    public static func relinked(after error: any Error, link: @escaping @MainActor @Sendable () -> AnyObject?,
                                drop: () -> Void, refused: @escaping @MainActor @Sendable () -> Bool,
                                up: () async -> Bool) async -> Bool {
        if linkStale(error), let stale = link() {
            drop()
            _ = await holds(within: relinkWait) { refused() || link().map { $0 !== stale } ?? false }
        }
        return await up()
    }

    /// A start's failure as Rust's `wait::StartFailure` reads it.
    private struct StartFailure: Encodable {
        var kind: String, code: Int32?, what: String?
        init(_ error: any Error) {
            switch error {
            case DaemonError.connectionClosed: (kind, code, what) = ("connectionClosed", nil, nil)
            case DaemonError.connectFailed(_, let errno): (kind, code, what) = ("connectFailed", errno, nil)
            case DaemonError.timedOut(let request): (kind, code, what) = ("timedOut", nil, request)
            default: (kind, code, what) = ("other", nil, nil)
            }
        }
    }

    /// A refused start's machine `update`, then its new link: the update restarts the machine's daemon and its carrier
    /// rebinds the link socket, so starting again at once dialed the socket while it was gone (start matrix run
    /// 42125025387 on bcf992a1: a first chat with no folder on a new machine). As ``CloudOutdatedMachine/copy`` does,
    /// this waits, up to `relink`, for `handshake` (the connection's key) to change from what it was before. False when
    /// `update` ran no turn; true after the wait, whether the new handshake came or not (the start's next refusal stands).
    public static func updatedThenRelinked(handshake: @escaping @MainActor @Sendable () -> String?, relink: Duration = relinkWait,
                                           update: () async -> Bool) async -> Bool {
        let before = handshake()
        guard await update() else { return false }
        _ = await holds(within: relink) { CloudMoveCore().relinked(before: before, now: handshake(), refusedCounts: false) }
        return true
    }

    /// How long a start or a copy waits for a machine's new link after an update restarted its daemon.
    public nonisolated static var relinkWait: Duration { .milliseconds(CloudMoveCore.deadlines.relinkMs) }

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
        try await retriedOnce(start, closed: closed, relinkAfter: { _ in await relink() })
    }

    /// ``retriedOnce(_:closed:relink:)`` whose relink sees the failure: a stale link (``linkStale(_:)``) needs a new
    /// link, not the one the app still holds.
    public static func retriedOnce<T>(_ start: () async throws -> T, closed: (any Error) -> Bool,
                                      relinkAfter relink: (any Error) async -> Bool) async throws -> T {
        do {
            return try await start()
        } catch where closed(error) && !Task.isCancelled {
            guard await relink(error) else { throw error }
            return try await start()
        }
    }
}

/// A Cloud machine whose cmux-tui is older than the app's: the CLIs Move to Cloud, Bring Back Local
/// and a chat start's folder copy run (cmux-tui `link/machine_gate.rs`) refuse it with ``code``.
///
/// A new machine's image may carry an older cmux-tui than the app, and the automatic update its
/// first handshake queued may not have run yet. A chat start's copy (`cmux link start-chat copy`)
/// refused that way updates the machine to the app's own build and copies once more, on its new link (``copy(socket:link:notConnected:relink:_:answer:update:)``),
/// instead of failing the person's first send with "Update the machine".
public struct CloudOutdatedMachine {
    public init() {}
    /// The CLIs' error code for a daemon too old for the verb.
    public static let code = "machine_outdated"

    /// Whether an answer (`ok`, `error_code`, `side`) is the machine's older daemon refusing it (Rust's rule:
    /// ``code`` about the machine, never this Mac's own daemon).
    public static func updatesBeforeCopyingAgain(ok: Bool, errorCode: String?, side: String?) -> Bool {
        CloudMoveCore().updatesBeforeCopyingAgain(ok: ok, errorCode: errorCode, side: side)
    }

    /// How long a chat start waits for its own update of its machine before it goes on without it
    /// (``updateBeforeUsingCapability(holds:relink:within:update:)``, `CloudMachineRoute.prepare`). A machine whose host
    /// updater follows its channel never takes a build older than the one it applied (a DEV build of a branch usually is),
    /// and the start's card then said nothing for 8 minutes while the CLI waited 25 for an outcome that never came
    /// (2026-11-16). A minute and a half is about as long as a start can show "machine" before it reads as stalled; an
    /// update that does apply answers well within it, and it covers the start's own run's bound (``startUpdateRun``).
    public static let startUpdateWait: Duration = .seconds(90)

    /// The bound of a chat start's own `cmux link machine update` run (`CloudMoveCLI.machineUpdate(within:)`), under
    /// ``startUpdateWait``: past it the run ends as `machine_update_abandoned`, so the app's one update queue's turn ends
    /// with it and no later start or update of any machine waits behind it.
    public static let startUpdateRun: Duration = .seconds(75)

    /// `operation`'s value when it returns within `limit` on `clock`; nil when it did not (it is cancelled then), or the
    /// caller was cancelled.
    public static func bounded<T: Sendable, C: Clock & Sendable>(_ limit: Duration, clock: C, _ operation: @escaping @Sendable () async -> T) async -> T?
        where C.Duration == Duration {
        try? await withDeadline(limit, label: "cloud machine start update", clock: clock, operation)
    }

    /// Updates a machine before using a capability that its current daemon does not advertise.
    /// The update restarts the daemon, so this waits, up to `relink`, for `holds` itself (read from the
    /// new handshake), not just for the link to change: a new link may come up before its handshake
    /// carries the capability, and opening then was refused although the update had worked (capture at
    /// a799d97a, 2026-11-02). If the update cannot run, changed nothing (`update` false: a refusal), did not
    /// end within `limit`, or the capability does not arrive in time, this returns and the caller's existing
    /// capability refusal remains the final result.
    @MainActor
    public static func updateBeforeUsingCapability(
        holds: @escaping @MainActor @Sendable () -> Bool,
        relink: Duration = CloudWait.relinkWait,
        within limit: Duration = startUpdateWait,
        update: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        await updateBeforeUsingCapability(holds: holds, relink: relink, within: limit, clock: ContinuousClock(), update: update)
    }

    /// ``updateBeforeUsingCapability(holds:relink:within:update:)`` with its bounds on `clock` (a test's `ManualClock`).
    @MainActor
    public static func updateBeforeUsingCapability<C: Clock & Sendable>(
        holds: @escaping @MainActor @Sendable () -> Bool,
        relink: Duration = CloudWait.relinkWait,
        within limit: Duration = startUpdateWait,
        clock: C,
        update: @escaping @MainActor @Sendable () async -> Bool
    ) async where C.Duration == Duration {
        guard !holds() else { return }
        guard await bounded(limit, clock: clock, { await update() }) == true else { return }
        _ = await CloudWait.holds(within: relink, clock: clock, until: holds)
    }

    /// ``updateBeforeUsingCapability(holds:relink:within:update:)``, then `missing` thrown while `lacks` still holds: a
    /// start that needs a capability its machine's software lacks, and that the machine could not be updated to (the
    /// update was refused or did not end within `limit`), ends at once saying so instead of a chat its provider refuses.
    @MainActor
    public static func requireCapability(
        holds: @escaping @MainActor @Sendable () -> Bool,
        lacks: @MainActor () -> Bool,
        relink: Duration = CloudWait.relinkWait,
        within limit: Duration = startUpdateWait,
        update: @escaping @MainActor @Sendable () async -> Bool,
        missing: @autoclosure () -> any Error
    ) async throws {
        try await requireCapability(holds: holds, lacks: lacks, relink: relink, within: limit, clock: ContinuousClock(), update: update, missing: missing())
    }

    /// ``requireCapability(holds:lacks:relink:within:update:missing:)`` with its bounds on `clock` (a test's `ManualClock`).
    @MainActor
    public static func requireCapability<C: Clock & Sendable>(
        holds: @escaping @MainActor @Sendable () -> Bool,
        lacks: @MainActor () -> Bool,
        relink: Duration = CloudWait.relinkWait,
        within limit: Duration = startUpdateWait,
        clock: C,
        update: @escaping @MainActor @Sendable () async -> Bool,
        missing: @autoclosure () -> any Error
    ) async throws where C.Duration == Duration {
        await updateBeforeUsingCapability(holds: holds, relink: relink, within: limit, clock: clock, update: update)
        if lacks() { throw missing() }
    }

    /// Runs `copy` on the machine's link socket (`socket`, nil when not connected: `notConnected` is thrown); when
    /// its answer (read by `answer`) is the machine's older daemon refusing it (``updatesBeforeCopyingAgain(ok:errorCode:side:)``)
    /// and `update` updated the machine (true), runs it once more. Otherwise the first answer stands: nothing else updates it.
    ///
    /// The update restarts the machine's daemon and its link comes back on a new socket: copying again on the
    /// first one failed with "cannot connect to …/cmux-link-….sock: No such file or directory" (capture at
    /// ff3f8c9b, 2026-11-01). So the second copy waits, up to `relink`, for `link` (the connection's handshake
    /// key) to change from what it was before the update, and reads the socket again.
    @MainActor
    public static func copy<Answer>(socket: () async -> String?, link: @escaping @MainActor @Sendable () -> String?, notConnected: any Error,
                                    relink: Duration = CloudWait.relinkWait, _ copy: (String) async throws -> Answer,
                                    answer: (Answer) -> (ok: Bool, errorCode: String?, side: String?), update: () async -> Bool) async throws -> Answer {
        guard let path = await socket() else { throw notConnected }
        let before = link()
        let first = try await copy(path)
        let read = answer(first)
        guard updatesBeforeCopyingAgain(ok: read.ok, errorCode: read.errorCode, side: read.side), await update() else { return first }
        _ = await CloudWait.holds(within: relink) { CloudMoveCore().relinked(before: before, now: link(), refusedCounts: true) }
        guard let again = await socket() else { throw notConnected }
        return try await copy(again)
    }
}

/// The workspace on a Cloud machine where its terminals and chats land (`CloudHandlers.terminalAnchor`:
/// a chat start's chat, `cloud start-session`, a browser tab): the machine's first workspace, or a new
/// one when it has none.
///
/// The app finds a workspace by its id alone (`MachineRegistry.workspace(id:)`: this Mac's tree, then
/// the first machine's that lists it), and machines made from one image list the same key for their
/// first workspace (capture d143d61c: cloud-chats and cloud-chats-3 both listed workspace-1 as
/// a40723c3-…). A chat opened in such a workspace was shown in another machine's: the window showed
/// cloud-chats-2's empty chat, the chat on cloud-chats never loaded its page, and its seeded first
/// message, handed over only at the page's handshake, never went. So a workspace another machine
/// (or this Mac) also lists (`listedElsewhere`) is never the anchor: a new one is made instead.
@MainActor
public struct CloudMachineWorkspace {
    public init() {}

    public static func targetAnchor(_ paneID: String, in store: DaemonStore) -> (id: String, key: WorkspaceKey, pane: PaneModel)? {
        for workspace in store.workspaces {
            guard let key = workspace.key else { continue }
            if let pane = workspace.screens.flatMap(\.panes).first(where: { $0.resourceID?.rawValue == paneID }) {
                return (workspace.id, key, pane)
            }
        }
        return nil
    }

    /// The first workspace `store` lists that no other tree lists, nil when it has none. A daemon's
    /// connection is up before its first tree is applied (right after a resume), and the list then is
    /// the last connection's, not "none": the read waits for this connection's tree (`liveTreeEpoch`),
    /// up to `limit`, so an open never makes a second workspace. The connection is published before
    /// the store hears `.connected` (which moves the epoch), so the store must say connected too. A
    /// tree that never comes within `limit` throws `notConnected`: never "none", which would make one.
    public static func existing(in store: DaemonStore, within limit: Duration = .milliseconds(CloudMoveCore.deadlines.workspaceTreeMs), notConnected: @autoclosure () -> any Error,
                                listedElsewhere: (String) -> Bool = { _ in false }) async throws -> String? {
        guard await live(store, within: limit) else { throw notConnected() }
        return store.workspaces.lazy.map(\.id).first { !listedElsewhere($0) }
    }

    /// Whether `store` is connected with this connection's tree applied, waiting up to `limit` for it: what
    /// ``existing(in:within:notConnected:listedElsewhere:)`` reads before it trusts the list. A connection that is
    /// down and dialing again by itself is not live, though the daemon still holds it.
    public static func live(_ store: DaemonStore, within limit: Duration) async -> Bool {
        let current = { @MainActor @Sendable in
            if case .connected = store.connectionState { return store.liveTreeEpoch == store.connectionEpoch }
            return false
        }
        if current() { return true }
        return await CloudWait.holds(within: limit, until: current)
    }

    /// ``existing(in:within:notConnected:listedElsewhere:)``, else a workspace `create` makes (nil:
    /// `notConnected`), after `beforeCreate`, whose throw makes none. `created` says which.
    public static func first(in store: DaemonStore, notConnected: @autoclosure () -> any Error, listedElsewhere: (String) -> Bool = { _ in false },
                             beforeCreate: () throws -> Void, create: () async -> String?) async throws -> (id: String, created: Bool) {
        if let first = try await existing(in: store, notConnected: notConnected(), listedElsewhere: listedElsewhere) { return (first, false) }
        // The live tree, rather than the stale pre-wait tree, decides whether creation needs consent.
        try beforeCreate()
        guard let id = await create() else { throw notConnected() }
        return (id, true)
    }

    /// A Cloud chat start's own workspace (`CloudStartChat`, `cmux link start-chat`): the chat is its one tab, made with
    /// it, and no terminal is ever made for it. It is never the machine's first workspace (``first(in:notConnected:listedElsewhere:beforeCreate:create:)``):
    /// that one holds the starter shell (the image's, or the terminal a plain workspace create opens), which showed as a
    /// second tab beside the chat. Its key is the start's (``chatKey(tabKey:)``): `create` makes it with the chat as its
    /// first tab; a retry that finds it listed only `open`s the chat in it again (keyed, so the same tab), and makes nothing.
    public static func chat<Tab>(tabKey: String, in store: DaemonStore, within limit: Duration = .milliseconds(CloudMoveCore.deadlines.workspaceTreeMs),
                                 notConnected: @autoclosure () -> any Error, open: (WorkspaceHandle) async throws -> Tab,
                                 create: (WorkspaceKey) async throws -> Tab) async throws -> (key: WorkspaceKey, tab: Tab, created: Bool) {
        guard await live(store, within: limit) else { throw notConnected() }
        let key = chatKey(tabKey: tabKey)
        if let listed = store.workspaces.first(where: { $0.key == key }) { return (key, try await open(listed.handle), false) }
        return (key, try await create(key), true)
    }

    /// The composer start's chat open (`CloudStartChat`: ``chat(tabKey:in:within:notConnected:open:create:)`` and its
    /// mirrored tab), tried once more when the machine's link was down or dropped under it, once the link is live again
    /// (up to `relink`). A new machine's link reconnects after its software update and when remote approvals come on,
    /// which can land on the open: the start read no connection and answered "didn't connect. Retry once it's online."
    /// half a second after the machine connected, then deleted the machine (DEV 0b53cf17, 2026-11-15). The open is keyed,
    /// so the second try gets the same workspace and tab. A request that failed on a closed connection counts as a drop
    /// too (``CloudWait/linkDropped(_:)``): the daemon's restart can end the request before the store hears of it. A
    /// failure with the link up, or a link that stays down, throws as it is.
    public static func chatRelinked<T>(in store: DaemonStore, held: () -> Bool, relink: Duration = CloudWait.relinkWait,
                                       _ open: () async throws -> T) async throws -> T {
        let before = store.connectionEpoch
        return try await CloudWait.retriedOnce(open, closed: { store.connectionEpoch != before || !held() || CloudWait.linkDropped($0) },
                                               relink: { await live(store, within: relink) })
    }

    /// ``chat(tabKey:in:within:notConnected:open:create:)`` once its workspace mirrors (`anchor`: its first pane, by
    /// workspace id), with the chat's tab in it: a CLI or agent start's chat (`cloud start-session`), its workspace's only
    /// tab. `open` and `create` answer the chat's surface. Throws `notConnected` when the tab never shows.
    public static func chatTab(tabKey: String, in store: DaemonStore, notConnected: @autoclosure () -> any Error,
                               anchor: (String) async -> (id: String, key: WorkspaceKey, pane: PaneModel)?,
                               open: (WorkspaceHandle) async throws -> SurfaceID?, create: (WorkspaceKey) async throws -> SurfaceID?)
        async throws -> (anchor: (id: String, key: WorkspaceKey, pane: PaneModel), tab: (key: String, surface: SurfaceID)) {
        let made = try await chat(tabKey: tabKey, in: store, notConnected: notConnected(), open: open, create: create)
        guard let surface = made.tab, let found = await anchor(made.key.rawValue),
              let tab = found.pane.tabs.first(where: { $0.surface == surface }) else { throw notConnected() }
        return (found, (tab.id, surface))
    }

    /// The workspace key of the chat start `tabKey`: a UUID (version 5 layout) of its SHA-256, the same for every retry.
    public nonisolated static func chatKey(tabKey: String) -> WorkspaceKey {
        var bytes = Array(SHA256.hash(data: Data("cmux-cloud-chat-workspace\u{0}\(tabKey)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return WorkspaceKey(rawValue: (NSUUID(uuidBytes: bytes) as UUID).uuidString.lowercased())
    }
}
