import CmuxNextCompat
public import CmuxNextDaemon
import Foundation
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

    /// `start`, tried once more when its first try failed on a connection that closed (`closed`), once `relink`
    /// says the link is back: a just-resumed machine's link can drop once under a start (prod, 2026-11-05: "started
    /// but its agent didn't (cmux-tui connection closed: EOF)"). Any other failure, a second one, or a link that
    /// does not come back throws as it is.
    /// Whether a start's failure is its link dropping under it, which a relink and one more try can help (``retriedOnce``'s
    /// `closed`): the connection closed (an EOF right after a resume), or the link socket was gone or refused while its
    /// carrier rebound it (`connect …/cmux-link-….sock failed: No such file or directory`, start matrix run 42125025387).
    public nonisolated static func linkDropped(_ error: any Error) -> Bool {
        struct Failure: Encodable { var kind: String, code: Int32? }
        struct Reply: Decodable { var dropped: Bool }
        let failure = switch error {
        case DaemonError.connectionClosed: Failure(kind: "connectionClosed", code: nil)
        case DaemonError.connectFailed(_, let code): Failure(kind: "connectFailed", code: code)
        default: Failure(kind: "other", code: nil)
        }
        return CloudMoveCore().call("link_dropped", failure, as: Reply.self)?.dropped ?? false
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
        do {
            return try await start()
        } catch where closed(error) && !Task.isCancelled {
            guard await relink() else { throw error }
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

    /// Updates a machine before using a capability that its current daemon does not advertise.
    /// The update restarts the daemon, so this waits, up to `relink`, for `holds` itself (read from the
    /// new handshake), not just for the link to change: a new link may come up before its handshake
    /// carries the capability, and opening then was refused although the update had worked (capture at
    /// a799d97a, 2026-11-02). If the update cannot run or the capability does not arrive in time, this
    /// returns and the caller's existing capability refusal remains the final result.
    @MainActor
    public static func updateBeforeUsingCapability(
        holds: @escaping @MainActor @Sendable () -> Bool,
        relink: Duration = CloudWait.relinkWait,
        update: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        guard !holds() else { return }
        guard await update() else { return }
        _ = await CloudWait.holds(within: relink, until: holds)
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
}
