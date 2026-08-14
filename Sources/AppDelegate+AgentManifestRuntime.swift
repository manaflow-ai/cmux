import CmuxCore
import Foundation

extension AppDelegate {
    func startAgentManifestRuntime() {
        agentManifestReloadObserver = NotificationCenter.default.addObserver(
            forName: .cmuxAgentManifestsDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.agentManifestsDidReload()
            }
        }
        Task { await agentManifestRuntime.start() }
        StartupBreadcrumbLog.append("appDelegate.didFinish.agentManifests.watcherStarted")
    }

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
        guard let runtime = shared?.agentManifestRuntime else {
            return (nil, nil)
        }
        return await runtime.state()
    }

    @MainActor
    func agentManifestsDidReload() {
        SharedLiveAgentIndex.shared.invalidateForAgentManifestReload()
    }
}
