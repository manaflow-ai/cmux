import Foundation

extension AcpmuxEnvironment {
    /// Clears this daemon's persisted peer tails on sign-out. Rust orders deletion after queued
    /// captures and bars late replies from earlier peer instances. With no daemon, the CLI
    /// takes its lock and clears from disk. Never starts a daemon.
    public nonisolated func clearPeerSnapshots() async throws {
        let variables = ProcessInfo.processInfo.environment.merging(childEnvironment) { _, own in own }
        let status = await ProcessLauncher().run(executable, arguments: ["__clear-peer-snapshots"], environment: variables)
        guard status == 0 else { throw AcpmuxStatusClient.Failure.rpc("peer snapshot removal did not complete") }
    }
}
