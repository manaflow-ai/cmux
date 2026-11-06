import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import os

extension ChiefConversationOwner {
    /// Whether this app hands its Chief owner off to its bundled build after an update, from what
    /// the owner says of itself (`identify`'s `cli_path` and `build_commit`; cmux-next never
    /// inspects another process). Only from a bundled binary (an external `CMUX_NEXT_TUI_BIN`
    /// would start as itself again), and only for an owner whose binary is no live build's own:
    ///
    /// - its file is gone (the app it ran from was deleted or moved away), or
    /// - it is this app's own bundled binary's path and the owner runs another build: an update
    ///   wrote this build over the file the owner was started from.
    ///
    /// An owner run by another install's binary that still exists is never handed off: that
    /// build may still run and share this home (NIGHTLY's, or `CMUX_NEXT_CHIEF_HOME`), and each
    /// launch would restart the other's owner in turn. An owner that does not say its path (from
    /// before `daemon-build-v1`) is kept. `bundledCommit` is read only when the paths match.
    nonisolated static func handsOffForUpdate(binaryIsBundled: Bool, ownerPath: String?, ownerCommit: String?,
                                              bundledPath: String, bundledCommit: () async -> String?,
                                              fileExists: (String) -> Bool) async -> Bool {
        guard binaryIsBundled, let ownerPath else { return false }
        guard fileExists(ownerPath) else { return true }
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        guard resolved(ownerPath) == resolved(bundledPath), let ownerCommit,
              let bundled = await bundledCommit() else { return false }
        return ownerCommit != bundled
    }

    /// ``handsOffForUpdate(binaryIsBundled:ownerPath:ownerCommit:bundledPath:bundledCommit:fileExists:)``
    /// for the owner `identity`, read off the main actor (file checks, the bundled `--version`).
    @concurrent nonisolated static func ownerReplaced(identity: DaemonIdentity, launcher: DaemonLauncher) async -> Bool {
        await handsOffForUpdate(binaryIsBundled: launcher.configuration.binaryIsBundled, ownerPath: identity.cliPath,
                                ownerCommit: identity.buildCommit, bundledPath: launcher.configuration.binary.path,
                                bundledCommit: { try? await launcher.bundledBuildCommit() },
                                fileExists: { FileManager.checked.fileExists(atPath: $0) })
    }

    /// After an update replaced the binary the Chief owner runs from: hand it off once, while it
    /// is idle (`OwnerIdleProbe`: no Chief turn, no other app, page or `cmux chief` chat), so the
    /// next `ensure` starts this build's owner on the same home and state. The handoff keeps its
    /// conversations on disk, as every owner handoff does; a busy owner keeps running until the
    /// returned restart, fed the owner's events, finds it idle. Nil when no handoff is needed.
    static func restartIfReplaced(launcher: DaemonLauncher, connection: DaemonConnection,
                                  identity: DaemonIdentity, logger: Logger) async -> IdleOwnerRestart? {
        guard await ownerReplaced(identity: identity, launcher: launcher) else { return nil }
        let pid = identity.pid
        let restart = IdleOwnerRestart(probe: OwnerIdleProbe(connection)) {
            // Only the owner this connection found replaced: another owner process after a
            // reconnect is not (the pid fence would refuse it anyway).
            guard await connection.identity?.pid == pid else { return false }
            let started = await launcher.handOffForUpdate(identity: identity, using: connection)
            logger.info("chief owner \(pid) runs a replaced build; hand off to this build: \(started ? "started" : "refused", privacy: .public)")
            return started
        }
        if await restart.attempt() == .waiting {
            logger.info("chief owner \(pid) runs a replaced build and is busy; it hands off once it is idle")
        }
        return restart
    }
}
