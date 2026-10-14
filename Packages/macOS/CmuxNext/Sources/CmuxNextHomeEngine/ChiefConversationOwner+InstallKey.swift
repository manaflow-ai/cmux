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
    /// (`OwnerIdleProbe`: no Chief turn running, no other app or page connected). A busy owner
    /// stays as it is (the page's Create Chief keeps getting "needs a verified cmux app
    /// connection") until it restarts. A signed build holds no key and never restarts it.
    static func restartIfUnverified(home: ChiefHome, launcher: DaemonLauncher, connection: DaemonConnection,
                                    identity: DaemonIdentity, logger: Logger) async {
        guard launcher.configuration.installKey != nil, mayRestartForInstallKey(home: home),
              !(await connection.userOriginAllowed) else { return }
        guard await OwnerIdleProbe(connection).isIdle() else {
            logger.info("chief owner \(identity.pid) does not verify this app and is busy; it keeps running unverified")
            return
        }
        let restarting = await launcher.handOffForInstallKey(identity: identity, using: connection)
        logger.info("chief owner \(identity.pid) does not verify this app; restart with the install key: \(restarting ? "started" : "refused", privacy: .public)")
    }
}
