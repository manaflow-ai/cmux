import Foundation

@MainActor
final class SurfaceResumeBindingVaultCWDPolicyResolver {
    private let homeDirectory: String
    private let environment: [String: String]
    private let fileManager: FileManager
    private var registriesByWorkingDirectory: [String?: CmuxVaultAgentRegistry] = [:]

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
        let key = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let registry = registriesByWorkingDirectory[key] {
            return registry
        }
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: homeDirectory,
            workingDirectory: key,
            environment: environment,
            fileManager: fileManager
        )
        registriesByWorkingDirectory[key] = registry
        return registry
    }
}
