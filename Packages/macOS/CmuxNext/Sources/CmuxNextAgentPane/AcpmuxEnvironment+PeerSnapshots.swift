public import CmuxNextCompat
public import CmuxNextWakeups
import Foundation

extension AcpmuxEnvironment {
    /// Clears the pane cache and its daemon-owned disk copies after Cloud links have ended.
    @MainActor public static func clearPeerTails(build: BuildIdentity?, work: BackgroundWork) async throws {
        AgentPaneTailCache.shared.clear()
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let acpmux = try await work.run(.userVisible, mayBlock: .files) {
            resolve(build: build, bundledBinDirectory: bin, environment: environment, userHome: userHome)
        }
        guard let acpmux else { throw AcpmuxStatusClient.Failure.rpc("acpmux executable unavailable for peer snapshot removal") }
        try await acpmux.clearPeerSnapshots()
    }

    /// Clears this daemon's persisted peer tails on sign-out. Rust orders deletion after queued
    /// captures and bars late replies from earlier peer instances. With no daemon, the CLI
    /// takes its lock and clears from disk. Never starts a daemon.
    public nonisolated func clearPeerSnapshots() async throws {
        let variables = ProcessInfo.processInfo.environment.merging(childEnvironment) { _, own in own }
        let status = await ProcessLauncher().run(executable, arguments: ["__clear-peer-snapshots"], environment: variables)
        guard status == 0 else { throw AcpmuxStatusClient.Failure.rpc("peer snapshot removal did not complete") }
    }
}
