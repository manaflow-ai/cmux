import CMUXAgentLaunch
import Foundation

/// What started a Claude account switch.
enum ClaudeAccountSwitchTrigger: Sendable {
    /// The user picked an account from a menu, the command palette or the CLI.
    case manual
    /// cmux switched on its own, for example after a usage limit.
    case automatic

    /// The accounts a switch with this trigger may choose from and plan against.
    ///
    /// A manual switch uses the user `cmux.json` plus the nearest project `.cmux/cmux.json`
    /// above the pane, where a project entry replaces a user entry of the same name. The
    /// automatic switch runs unattended, so it uses the user-level file only: a repository must
    /// not add an account to it or point one of the user's accounts at a directory it controls.
    ///
    /// - Parameters:
    ///   - homeDirectory: The home whose `.config/cmux/cmux.json` is read.
    ///   - paneWorkingDirectory: Where a manual switch looks for a project config.
    func accountRegistry(homeDirectory: String, paneWorkingDirectory: String?) -> ClaudeAccountRegistry {
        let sanitize: (Data) throws -> Data = { try JSONCParser.preprocess(data: $0) }
        switch self {
        case .manual:
            return ClaudeAccountRegistry.load(
                homeDirectory: homeDirectory,
                workingDirectory: paneWorkingDirectory,
                sanitize: sanitize
            )
        case .automatic:
            return ClaudeAccountRegistry.loadUserLevel(homeDirectory: homeDirectory, sanitize: sanitize)
        }
    }

    /// Plans moving a Claude session to `targetName`, resolving the account through
    /// ``accountRegistry(homeDirectory:paneWorkingDirectory:)``: the switch's one planning step.
    func plan(
        sessionID: String?,
        workingDirectory: String?,
        launchEnvironment: [String: String]?,
        targetName: String,
        homeDirectory: String,
        paneWorkingDirectory: String?
    ) -> Result<ClaudeAccountSwitchPlan, ClaudeAccountSwitchRefusal> {
        ClaudeAccountSwitchPlanner.plan(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            launchEnvironment: launchEnvironment,
            targetName: targetName,
            registry: accountRegistry(homeDirectory: homeDirectory, paneWorkingDirectory: paneWorkingDirectory),
            homeDirectory: homeDirectory
        )
    }
}
