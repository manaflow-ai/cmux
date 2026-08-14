import CmuxCore
import Foundation

enum ControlSidebarAgentLifecycleRegistryScope: Sendable {
    case project(String?)
    case globalOnly

    func loadRegistry(
        homeDirectory: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        manifestSnapshot: CmuxAgentManifestSnapshot? = nil
    ) -> CmuxVaultAgentRegistry {
        switch self {
        case .project(let workingDirectory):
            return CmuxVaultAgentRegistry.load(
                homeDirectory: homeDirectory,
                workingDirectory: workingDirectory,
                environment: environment,
                fileManager: fileManager,
                manifestSnapshot: manifestSnapshot
            )
        case .globalOnly:
            return CmuxVaultAgentRegistry.load(
                homeDirectory: homeDirectory,
                environment: [:],
                fileManager: fileManager,
                manifestSnapshot: manifestSnapshot
            )
        }
    }
}
