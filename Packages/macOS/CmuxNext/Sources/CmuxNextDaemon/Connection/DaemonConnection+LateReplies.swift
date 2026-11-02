import CmuxNextWakeups
import Foundation
import os

/// A change the person already sees (Cmd-N's workspace shows at the press) must not be taken back
/// because the daemon answered it after the 2 s control deadline: a busy daemon still commits it
/// (cx-tzlqb), and taking it back closed a workspace the person was looking at. Sent again with the
/// same mutation identity, a committed change replays its result instead of committing twice (as
/// ``NewFrontendBrowserTabRequest/send(on:)`` does for keyed browser tabs).
extension DaemonConnection {
    private static let lateReplyLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")

    /// When a change that starts now stops asking again: one budget for every step of it (Cmd-N's
    /// pin, create and first tab share one), so a daemon that never answers holds the window's
    /// create lane about this long, not this long per step.
    public static func lateReplyDeadline() -> ContinuousClock.Instant {
        ContinuousClock.now + NewFrontendBrowserTabRequest.lateReplyBudget
    }

    /// Runs `send` again while it misses its reply deadline (`DaemonError.timedOut`), until
    /// `giveUp` (default: ``lateReplyDeadline()`` from now), and returns its first answer.
    /// `send` must repeat one change: a request with a fixed mutation identity (the daemon replays
    /// it), or one whose effect repeats harmlessly (a pin). Any other error, and a timeout past the
    /// budget, is thrown. Each pass waits out a whole deadline, so it never spins.
    public static func retryingLateReplies<T>(_ what: String, until giveUp: ContinuousClock.Instant? = nil,
                                              _ send: () async throws -> T) async throws -> T {
        let giveUp = giveUp ?? lateReplyDeadline()
        // wakeup-allow: each pass waits for one reply or its deadline; the retry ends at the budget, on a reply, or on another error
        while true {
            do {
                return try await send()
            } catch DaemonError.timedOut(let request) where ContinuousClock.now < giveUp && !Task.isCancelled {
                lateReplyLogger.info("\(what, privacy: .public): \(request, privacy: .public) timed out; asking again"); print("CHATOPEN-DIAG t=\(String(format: "%.1f", ProcessInfo.processInfo.systemUptime * 1000)) late-reply-retry \(what) \(request)")
            }
        }
    }

    /// `create-terminal` in workspace `key` that waits for the terminal on a loaded host: sent again
    /// under one terminal id and mutation identity while it misses its start deadline
    /// (`DaemonError.terminalStartTimedOut`), so the terminal the daemon starts late is the one
    /// returned and none is started twice (``requestWaitingForStart(_:)``).
    @discardableResult
    public func createTerminalWaitingForStart(in key: WorkspaceKey, cwd: String?) async throws -> CreateTerminalResult {
        try await requestWaitingForStart(await createTerminalRequest(in: key, cwd: cwd))
    }

    /// Sends `request`, a terminal start cmux-tui replays (a keyed `create-terminal`, or a `split`,
    /// `new-pane` or `new-pane-right` under its client-minted ids), again while it misses its
    /// start deadline, so the terminal a loaded host starts late is the one returned and none is started
    /// twice. Each pass waits out one whole deadline, and a pass sent again is the same keyed creation, so
    /// a re-send changes nothing on the daemon. It ends on the reply, the daemon's refusal, the
    /// connection's end (`notConnected`, `connectionClosed`) or the task's cancellation
    /// (`CancellationError`), never on a client clock: a give-up after a fixed budget took back a pane the
    /// window showed while the daemon still made it (P0 2026-10-30, principled-audit R5, R-L5).
    func requestWaitingForStart<R: TerminalSpawningRequest>(_ request: R) async throws -> R.Response {
        do {
            return try await Self.waitingThroughLateReplies(R.command) { try await self.request(request) }
        } catch {
            // R3: a new terminal is never taken back on a client clock (DEBUG; the loop ends only on other errors).
            Self.checkNoLateStart(error, R.command)
            throw error
        }
    }

    /// DEBUG: `error` ended a wait that must outlast every client deadline (``waitingThroughLateReplies(_:_:)``).
    static func checkNoLateStart(_ error: any Error, _ what: String) {
        #if DEBUG
        // crash-allow: DEBUG-only invariant check (R3); waitingThroughLateReplies never ends on a late start
        if (error as? DaemonError)?.isLateStart == true { assertionFailure("R3: \(what) gave up on a late start") }
        #endif
    }

    /// A workspace's first terminal (Cmd-N's, a terminal-first new workspace's): `request` carries its
    /// client-chosen terminal id and mutation identity, so it waits through a late start
    /// (``requestWaitingForStart(_:)``) instead of failing at the start deadline, which closed the
    /// workspace the person already saw while the daemon still made the terminal (P0 2026-10-30).
    @discardableResult
    public func createTerminalWaitingForStart(_ request: CreateTerminalRequest) async throws -> CreateTerminalResult {
        try await requestWaitingForStart(request)
    }

    /// `create-workspace` for workspace `key` that waits through late replies under one mutation identity
    /// (the daemon replays it), with no budget: it ends on the reply, the daemon's refusal, the connection's
    /// end or cancellation (``waitingThroughLateReplies(_:_:)``). For a workspace with a first terminal.
    @discardableResult
    public func createWorkspaceWaitingForReply(name: String? = nil, key: WorkspaceKey) async throws -> WorkspaceMutationResult {
        let request = CreateWorkspaceRequest(name: name, key: key, mutation: mutation())
        do {
            return try await Self.waitingThroughLateReplies(CreateWorkspaceRequest.command) { try await self.request(request) }
        } catch {
            Self.checkNoLateStart(error, CreateWorkspaceRequest.command) // R3 (DEBUG)
            throw error
        }
    }

    /// Runs `send` again while it misses its reply or start deadline, and repeats one keyed change the daemon
    /// replays. It ends on the reply, the daemon's refusal or any other error, the connection's end (`notConnected`,
    /// `connectionClosed`) or the task's cancellation (`CancellationError`), never on a client clock (principled-audit
    /// R5, R-L5). A re-send only repairs a lost request, so it is spaced by full-jitter exponential backoff
    /// (``lateReplyBackoff``, R-L4), never at the fixed deadline: a hung daemon gets no retry storm.
    static func waitingThroughLateReplies<T>(_ what: String, _ send: () async throws -> T) async throws -> T {
        var backoff = lateReplyBackoff()
        // wakeup-allow: each pass waits for one reply or its deadline, then a jittered backoff; it ends on a reply, a refusal, the connection's end or cancellation
        while true {
            do {
                return try await send()
            } catch let error as DaemonError where error.isLateStart {
                lateReplyLogger.info("\(what, privacy: .public): \(String(describing: error), privacy: .public); asking again with its client ids")
                // concurrency-allow: Backoff.wait is an async sleep after a late reply, not a blocking wait.
                try await backoff.wait(owner: "DaemonConnection.lateReply")
            }
        }
    }

    /// The spacing of late-reply re-sends: full jitter from 1 s, doubling, capped at 30 s.
    static func lateReplyBackoff() -> Backoff { .fullJitter(initial: .seconds(1), maximum: .seconds(30)) }

    /// A pane creation (`split`, `new-pane`, `new-pane-right`) with its client-minted ids: waited for through a
    /// late start where the daemon replays a creation sent again with them (`split-client-keys-v1`), sent once on
    /// an older daemon, which would make a second pane. (`new-row` is not replayed: ``RowCommands`` sends it once.)
    func requestPaneCreation<R: TerminalSpawningRequest>(_ request: R) async throws -> R.Response {
        guard identity?.supports(DaemonCapability.splitClientKeys.rawValue) == true else { return try await self.request(request) }
        return try await requestWaitingForStart(request)
    }

    /// `create-workspace` for workspace `key`, sent again on a late reply under one mutation
    /// identity (the daemon replays a create that committed after the deadline).
    @discardableResult
    public func createWorkspaceRetryingLateReplies(name: String? = nil, key: WorkspaceKey,
                                                   until giveUp: ContinuousClock.Instant? = nil) async throws -> WorkspaceMutationResult {
        let request = CreateWorkspaceRequest(name: name, key: key, mutation: mutation())
        return try await Self.retryingLateReplies(CreateWorkspaceRequest.command, until: giveUp) { try await self.request(request) }
    }
}

private extension DaemonError {
    /// A reply that missed its deadline: the daemon may still be doing the work.
    var isLateStart: Bool {
        switch self {
        case .terminalStartTimedOut, .timedOut: true
        default: false
        }
    }
}
