import CmuxNextCloud
import Foundation

/// Set Up GitHub on This Machine asks first whether the machine's team can use the cmux GitHub App
/// (``CloudGitHubApp``), with the person's own session against the API Worker, for the team the
/// install token names (the team whose Cloud machines the Worker holds, as the approvals route uses).
extension CloudService {
    /// The whole check, install token included, answers within ``gitHubAppDeadline``: with the setup
    /// exec after it (``CloudGitHubSetup/timeoutMs`` plus its send margin) it stays inside
    /// `action.run`'s 40 s result deadline. A check that misses it is ``CloudGitHubApp/unknown``: the
    /// device flow.
    func gitHubApp() async -> CloudGitHubApp {
        let auth = auth, identity = installIdentity
        let signedInTeam = auth.teamID
        let baseURL = FeedService.apiBaseURL(auth: auth)
        let accessToken: @Sendable () async throws -> String = { try await auth.tokens().access }
        return await Self.firstAnswer(within: Self.gitHubAppDeadline, otherwise: .unknown) {
            let claimed = (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:))
            guard let team = claimed ?? signedInTeam else { return CloudGitHubApp.unknown }
            let owner = CloudOwnerAPIClient(baseURL: baseURL, accessToken: accessToken, teamID: { team })
            return await owner.gitHubApp(team: team)
        }
    }

    /// 8 s for the App check, then at most 30 s for the setup exec (25 s plus 5 s), under 40 s.
    static let gitHubAppDeadline: Duration = .seconds(8)

    /// `work`'s answer, or `fallback` once `deadline` passes, without waiting for `work` to stop: an
    /// install-token mint does not stop on cancel, so a task group (which waits for its children)
    /// would not bound it. The late work is cancelled and its answer dropped.
    nonisolated static func firstAnswer<T: Sendable>(within deadline: Duration, otherwise fallback: T,
                                                     _ work: @escaping @Sendable () async -> T) async -> T {
        let gate = FirstAnswer<T>()
        return await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            gate.arm(done)
            // concurrency-allow: the losing task is cancelled and its answer ignored (FirstAnswer resumes once)
            let worker = Task { gate.give(await work()) }
            Task {
                // wakeup-allow: one-shot deadline for the GitHub App check
                try? await Task.sleep(for: deadline)
                worker.cancel()
                gate.give(fallback)
            }
        }
    }
}

/// Resumes its continuation with the first answer given; later answers are dropped.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func arm(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func give(_ value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
