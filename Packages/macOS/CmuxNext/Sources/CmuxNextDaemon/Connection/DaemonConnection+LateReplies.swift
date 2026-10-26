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
                lateReplyLogger.info("\(what, privacy: .public): \(request, privacy: .public) timed out; asking again")
            }
        }
    }

    /// How long a create waits for a terminal a busy host starts late (``createTerminalWaitingForStart(in:cwd:)``).
    /// Each pass waits for the daemon's reply up to the start deadline; on a loaded host a start can
    /// take far longer than one deadline (Leo, 2026-10-21), and the daemon replays the start that
    /// lands, so the budget only bounds a daemon that never answers.
    public static let lateTerminalStartBudget: Duration = .seconds(120)

    /// `create-terminal` in workspace `key` that waits for the terminal on a loaded host: sent again
    /// under one terminal id and mutation identity while it misses its start deadline
    /// (`DaemonError.terminalStartTimedOut`), so the terminal the daemon starts late is the one
    /// returned and none is started twice. A refusal is thrown at once; a start still late after
    /// ``lateTerminalStartBudget`` is thrown as the timeout.
    @discardableResult
    public func createTerminalWaitingForStart(in key: WorkspaceKey, cwd: String?) async throws -> CreateTerminalResult {
        let request = await createTerminalRequest(in: key, cwd: cwd)
        let giveUp = ContinuousClock.now + Self.lateTerminalStartBudget
        // wakeup-allow: each pass waits for one reply or its start deadline; the retry ends at the budget, on a reply, or on another error
        while true {
            do {
                return try await self.request(request)
            } catch let error as DaemonError where error.isLateStart && ContinuousClock.now < giveUp && !Task.isCancelled {
                Self.lateReplyLogger.info("create-terminal in \(key.rawValue, privacy: .public): \(String(describing: error), privacy: .public); waiting with its mutation id")
            }
        }
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
