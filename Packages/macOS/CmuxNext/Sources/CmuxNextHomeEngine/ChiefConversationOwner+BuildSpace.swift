import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import os

extension ChiefConversationOwner {
    /// The cloud build space the Chief owner was started with (`CMUX_BUILD_SPACE`, "" for nightly and stable), kept
    /// beside its state: `tui/build-space`. The owner's process environment is its own, so this file is how a later
    /// launch of the same build learns which space a running owner calls the cloud in.
    nonisolated static func buildSpaceRecord(home: ChiefHome) -> URL {
        home.daemonStateDirectory.appendingPathComponent("build-space", isDirectory: false)
    }

    /// This launch's space from the environment the owner is started with ("" for none).
    nonisolated static func buildSpace(of environment: [String: String]) -> String {
        environment[DaemonLauncher.buildSpaceKey] ?? ""
    }

    /// Records the space an owner is started with. Runs in ``ownerEnvironment(home:process:resources:)``, which runs
    /// only when `server ensure` spawns an owner, off the main actor.
    nonisolated static func recordBuildSpace(home: ChiefHome, environment: [String: String]) {
        let record = buildSpaceRecord(home: home)
        try? FileManager.checked.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(buildSpace(of: environment).utf8).blockingWrite(to: record, options: .atomic)
    }

    /// Whether the running owner calls the cloud in another space than this launch's: its record says another
    /// space, or it has none (an owner an older build started, before the space was passed) while this launch has
    /// one. Only for a home that is this build's alone (``mayRestartForInstallKey(home:)``): NIGHTLY's shared home
    /// holds no dev space, and an owner shared on purpose (`CMUX_NEXT_CHIEF_HOME`) is never restarted from here.
    @concurrent nonisolated static func ownerInOtherSpace(home: ChiefHome, environment: [String: String]) async -> Bool {
        guard mayRestartForInstallKey(home: home) else { return false }
        let expected = buildSpace(of: environment)
        let recorded = (try? Data(blockingContentsOf: buildSpaceRecord(home: home))).flatMap { String(data: $0, encoding: .utf8) }
        return (recorded ?? "") != expected
    }

    /// A dev build's Chief owner must call the cloud in this build's space only (AGENTS.md "Dev builds are
    /// separate"). When the running owner works in another space (an older build of this tag started it without
    /// `CMUX_BUILD_SPACE`), hand it off once, while it is idle (`OwnerIdleProbe`), so the next `ensure` starts it
    /// with this build's space. Its conversations stay on disk, as in every owner handoff. Nil when no handoff is
    /// needed.
    static func restartIfOtherSpace(home: ChiefHome, environment: [String: String], launcher: DaemonLauncher,
                                    connection: DaemonConnection, identity: DaemonIdentity, logger: Logger) async -> IdleOwnerRestart? {
        guard await ownerInOtherSpace(home: home, environment: environment) else { return nil }
        let restart = IdleOwnerRestart(probe: OwnerIdleProbe(connection)) {
            guard await connection.identity?.pid == identity.pid else { return false }
            let started = await launcher.handOffForBuildSpace(identity: identity, using: connection)
            logger.info("chief owner \(identity.pid) runs in another build space; restart it in this build's: \(started ? "started" : "refused", privacy: .public)")
            return started
        }
        if await restart.attempt() == .waiting {
            logger.info("chief owner \(identity.pid) runs in another build space and is busy; it restarts once it is idle")
        }
        return restart
    }
}
