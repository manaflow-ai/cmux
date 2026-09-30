import Foundation

extension CloudAgentSkillLauncher {
    enum LauncherError: LocalizedError {
        case skillResourceMissing

        var errorDescription: String? {
            switch self {
            case .skillResourceMissing:
                return String(
                    localized: "machines.agent.error.missingSkill",
                    defaultValue: "This build is missing the bundled cmux Cloud skill file."
                )
            }
        }
    }
}
