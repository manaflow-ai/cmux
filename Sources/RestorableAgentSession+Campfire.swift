import Foundation

extension AgentResumeCommandBuilder {
    /// Registry-owned built-ins use sanitizer-backed native argv only while the
    /// configured verb still matches that built-in. Project template overrides
    /// must remain authoritative.
    static func matchingBuiltInResumeKind(
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        let builtIns: [(String, CmuxVaultAgentRegistration)] = [
            ("pi", .builtInPi),
            ("omp", .builtInOmp),
            ("grok", .builtInGrok),
            ("campfire", .builtInCampfire),
            ("antigravity", .builtInAntigravity),
        ]
        return builtIns.first { kind, builtIn in
            registration.id.caseInsensitiveCompare(builtIn.id) == .orderedSame
                && registration.resumeCommand == builtIn.resumeCommand
        }?.0
    }

    static func matchingBuiltInForkKind(
        registration: CmuxVaultAgentRegistration
    ) -> String? {
        let builtIns: [(String, CmuxVaultAgentRegistration)] = [
            ("pi", .builtInPi),
            ("grok", .builtInGrok),
            ("campfire", .builtInCampfire),
        ]
        return builtIns.first { kind, builtIn in
            registration.id.caseInsensitiveCompare(builtIn.id) == .orderedSame
                && registration.forkCommand == builtIn.forkCommand
        }?.0
    }

    static func capturedOrRegisteredExecutablePath(
        registration: CmuxVaultAgentRegistration,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> String? {
        normalizedExecutable(launchCommand?.executablePath)
            ?? normalizedExecutable(launchCommand?.arguments.first)
            ?? registration.defaultExecutable
    }

    private static func normalizedExecutable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
