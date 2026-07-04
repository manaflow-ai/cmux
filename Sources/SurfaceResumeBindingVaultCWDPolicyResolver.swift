import Foundation

extension SurfaceResumeBindingSnapshot {
    var vaultAgentRegistrationID: String? {
        guard let id = kind?.trimmingCharacters(in: .whitespacesAndNewlines),
              let restorableKind = RestorableAgentKind(rawValue: id),
              restorableKind.usesVaultRegistryForCWDPolicy else {
            return nil
        }
        return restorableKind.rawValue
    }
}

private extension RestorableAgentKind {
    var usesVaultRegistryForCWDPolicy: Bool {
        switch self {
        case .custom, .grok, .pi, .antigravity:
            return true
        case .claude, .codex, .amp, .cursor, .gemini, .kiro, .opencode, .rovodev,
             .hermesAgent, .copilot, .codebuddy, .factory, .qoder:
            return false
        }
    }
}

@MainActor
final class SurfaceResumeBindingVaultCWDPolicyResolver {
    private enum WorkingDirectoryKey: Hashable {
        case inheritedEnvironment
        case explicit(String)

        init(_ workingDirectory: String?) {
            if let workingDirectory {
                self = .explicit(workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                self = .inheritedEnvironment
            }
        }

        var workingDirectory: String? {
            switch self {
            case .inheritedEnvironment:
                return nil
            case .explicit(let value):
                return value
            }
        }
    }

    private let homeDirectory: String
    private let environment: [String: String]
    private let fileManager: FileManager
    private var registriesByWorkingDirectory: [WorkingDirectoryKey: CmuxVaultAgentRegistry] = [:]

    init(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.fileManager = fileManager
    }

    func cwdPolicy(
        for binding: SurfaceResumeBindingSnapshot,
        fallbackWorkingDirectory: String?
    ) -> CmuxVaultAgentCWDPolicy? {
        guard let id = binding.vaultAgentRegistrationID else { return nil }
        return registry(workingDirectory: binding.cwd ?? fallbackWorkingDirectory)
            .registration(id: id)?
            .cwd
    }

    private func registry(workingDirectory: String?) -> CmuxVaultAgentRegistry {
        let key = WorkingDirectoryKey(workingDirectory)
        if let registry = registriesByWorkingDirectory[key] {
            return registry
        }
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: homeDirectory,
            workingDirectory: key.workingDirectory,
            environment: environment,
            fileManager: fileManager
        )
        registriesByWorkingDirectory[key] = registry
        return registry
    }
}
