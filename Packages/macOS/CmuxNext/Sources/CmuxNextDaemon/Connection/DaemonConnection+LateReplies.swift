import Foundation
import os

/// A change the person already sees (Cmd-N's workspace shows at the press) must not be taken back
/// because the daemon answered it after the 2 s control deadline: a busy daemon still commits it
/// (cx-tzlqb), and taking it back closed a workspace the person was looking at. Sent again with the
/// same mutation identity, a committed change replays its result instead of committing twice (as
/// ``NewFrontendBrowserTabRequest/send(on:)`` does for keyed browser tabs).
extension DaemonConnection {
    private static let lateReplyLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon")

    /// Runs `send` again while it misses its reply deadline (`DaemonError.timedOut`), until
    /// ``NewFrontendBrowserTabRequest/lateReplyBudget`` passes, and returns its first answer.
    /// `send` must repeat one change: a request with a fixed mutation identity (the daemon replays
    /// it), or one whose effect repeats harmlessly (a pin). Any other error, and a timeout past the
    /// budget, is thrown. Each pass waits out a whole deadline, so it never spins.
    public static func retryingLateReplies<T>(_ what: String, _ send: () async throws -> T) async throws -> T {
        let giveUp = ContinuousClock.now + NewFrontendBrowserTabRequest.lateReplyBudget
        // wakeup-allow: each pass waits for one reply or its deadline; the retry ends at the budget, on a reply, or on another error
        while true {
            do {
                return try await send()
            } catch DaemonError.timedOut(let request) where ContinuousClock.now < giveUp && !Task.isCancelled {
                lateReplyLogger.info("\(what, privacy: .public): \(request, privacy: .public) timed out; asking again with its mutation id")
            }
        }
    }

    /// `create-workspace` for workspace `key`, sent again on a late reply under one mutation
    /// identity (the daemon replays a create that committed after the deadline).
    @discardableResult
    public func createWorkspaceRetryingLateReplies(name: String? = nil, key: WorkspaceKey) async throws -> WorkspaceMutationResult {
        let request = CreateWorkspaceRequest(name: name, key: key, mutation: mutation())
        return try await Self.retryingLateReplies(CreateWorkspaceRequest.command) { try await self.request(request) }
    }
}
