import CmuxNextCloud
import CmuxNextCompat
import Foundation

/// Set Up GitHub on This Machine asks first whether the machine's team can use the cmux GitHub App
/// (``CloudGitHubApp``), with the person's own session against the API Worker, for the selected team
/// (the one the setup exec and the machine's token asks go to), else the team the install token names.
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
            // The selected team first: a shared-team machine's tokens come from that team's connection.
            let claimed = signedInTeam == nil ? (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) : nil
            guard let team = signedInTeam ?? claimed else { return CloudGitHubApp.unknown }
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
        let once = FirstAnswer<T>()
        return await withCheckedContinuation { (done: CheckedContinuation<T, Never>) in
            once.begin(done)
            // task-owner: the check's own work; cancelled by the deadline below, its late answer dropped
            let worker = Task { once.give(await work()) }
            // task-owner: one-shot deadline; it ends after `deadline`, and a give after the answer is a no-op
            Task {
                // wakeup-allow: one-shot deadline for the GitHub App check
                try? await Task.sleep(for: deadline)
                worker.cancel()
                once.give(fallback)
            }
        }
    }
}

/// Resumes a continuation once: the work's answer or the deadline's fallback, whichever comes first.
private nonisolated final class FirstAnswer<T: Sendable>: Sendable {
    private let state = Mutex<CheckedContinuation<T, Never>?>(nil)
    func begin(_ continuation: CheckedContinuation<T, Never>) { state.withLock { $0 = continuation } }
    func give(_ value: T) {
        state.withLock { slot -> CheckedContinuation<T, Never>? in defer { slot = nil }; return slot }?.resume(returning: value)
    }
}
