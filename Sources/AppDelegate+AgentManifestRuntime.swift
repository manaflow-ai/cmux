import CmuxCore
import Foundation

extension AppDelegate {
    nonisolated static func currentAgentManifestRuntimeState(
        homeDirectory: String = NSHomeDirectory()
    ) async -> (
        snapshot: CmuxAgentManifestSnapshot?,
        error: CmuxAgentManifestLoadError?
    ) {
        guard (homeDirectory as NSString).standardizingPath
            == (NSHomeDirectory() as NSString).standardizingPath else {
            return (nil, nil)
        }
        guard let runtime = await shared?.agentManifestRuntime else {
            return (nil, nil)
        }
        return await runtime.state()
    }

    @MainActor
    func agentManifestsDidReload() {
        SharedLiveAgentIndex.shared.invalidateForAgentManifestReload()
    }
}
