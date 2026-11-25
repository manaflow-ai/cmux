import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextSettings
import Foundation

/// "Use my GitHub login" on the person's Cloud machines (Leo, 2026-11-25: "Convienient beats all. Just make good ui for
/// it so people flow."). A Cloud start carries this Mac's own gh login to its machine before the machine clones or
/// copies, sealed to the machine's daemon (`git-host-tokens-v1`; ``CloudDaemon/carryGitHubLogin(_:deadline:)``). The
/// bundled cmux reads the token from gh itself, so it never passes through the app, an env file or a log. git and gh
/// on the machine use it first and fall back to the cmux GitHub App (cmux-host `github_own_login.rs`).
///
/// On by default (`cloud.useMyGitHubLogin`). A Mac with no gh login carries nothing, and the start's card offers
/// Sign in with GitHub when the machine can't reach the repository. Each machine gets it once per launch.
@MainActor
enum CloudGitHubLoginCarry {
    /// The machines that have this launch's login, by machine id, with when.
    private static var carried: [String: (at: Date, login: String?)] = [:]
    /// How long a carry counts: the person may change their gh login meanwhile.
    static let fresh: TimeInterval = 60 * 60

    /// Carries the login to `machineID` when the setting is on and it was not carried within ``fresh``.
    static func carry(_ services: AppServices, to machineID: String) async -> CloudDaemon.GitHubLoginCarry {
        let root = services.settings?.snapshot.root ?? .object([:])
        guard CloudNewWorkspaceSetting().useMyGitHubLogin(in: root) else { return .noLogin }
        if let done = carried[machineID], Date().timeIntervalSince(done.at) < fresh { return .carried(login: done.login) }
        let result = await services.cloud.machineAPI.daemon.carryGitHubLogin(machineID)
        switch result {
        case .carried(let login):
            carried[machineID] = (Date(), login)
            services.cloud.logger.info("cloud start: carried the GitHub login to \(machineID, privacy: .public)")
        case .failed(let code):
            services.cloud.logger.error("cloud start: GitHub login not carried to \(machineID, privacy: .public): \(code, privacy: .public)")
        case .noLogin, .forgotten: break
        }
        return result
    }

    /// What the start's card is told about the login when the machine can't reach the repository.
    static func detail(_ result: CloudDaemon.GitHubLoginCarry?) -> AgentPaneGitHubLogin {
        switch result {
        case .carried(let login): .carried(login: login)
        case .noLogin, nil: .none
        case .failed, .forgotten: .notCarried
        }
    }
}
