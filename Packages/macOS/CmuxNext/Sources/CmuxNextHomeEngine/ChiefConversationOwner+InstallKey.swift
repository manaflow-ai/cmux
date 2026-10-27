import CmuxNextDaemon
import os

extension ChiefConversationOwner {
    /// Whether this build may restart its Chief owner to give it the install key: only a home
    /// that belongs to this build alone (its own per-build home, or an isolated one). Never
    /// NIGHTLY's shared home (`~/.cmux/chief/<account>`) or a home named by
    /// `CMUX_NEXT_CHIEF_HOME`, which other builds use too: NIGHTLY is signed and verifies
    /// without a key, so its owner is never restarted for this.
    nonisolated static func mayRestartForInstallKey(home: ChiefHome) -> Bool {
        home.isolated || ChiefHome.hasOwnHome(bundleID: home.buildID)
    }

    /// An unsigned (DEV) build whose Chief owner does not verify it (an older build or
    /// `cmux chief` started the owner without this home's install key): restart the owner once,
    /// so `ensure` starts it again with the key on stdin, and only while it is idle
    /// (`OwnerIdleProbe`: no Chief turn running, no other app, page or `cmux chief` chat
    /// connected). A busy owner keeps running unverified (the page's Create Chief gets "needs a
    /// verified cmux app connection") until the returned restart, fed the owner's events, finds
    /// it idle. Nil when no restart is needed; a signed build holds no key and never restarts it.
    static func restartIfUnverified(home: ChiefHome, launcher: DaemonLauncher, connection: DaemonConnection,
                                    identity: DaemonIdentity, logger: Logger) async -> IdleOwnerRestart? {
        guard await launcher.configuration.installKey.key() != nil, mayRestartForInstallKey(home: home),
              !(await connection.userOriginAllowed) else { return nil }
        let restart = IdleOwnerRestart(probe: OwnerIdleProbe(connection)) {
            // Only the owner this connection found keyless: after a reconnect to another owner process the
            // restart is moot (the pid fence would refuse it anyway, and it spends the launcher's one handoff).
            guard await connection.identity?.pid == identity.pid else { return false }
            let started = await launcher.handOffForInstallKey(identity: identity, using: connection)
            logger.info("chief owner \(identity.pid) does not verify this app; restart with the install key: \(started ? "started" : "refused", privacy: .public)")
            return started
        }
        if await restart.attempt() == .waiting {
            logger.info("chief owner \(identity.pid) does not verify this app and is busy; it restarts with the install key once it is idle")
        }
        return restart
    }
}
