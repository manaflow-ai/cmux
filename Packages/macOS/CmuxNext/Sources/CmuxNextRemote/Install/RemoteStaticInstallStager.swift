public import Foundation
import os

/// Keeps the person's own `~/.cmux/bin/cmux` (``SSHHost/staticInstallBinary``, from
/// install-static.sh, run by hand over ssh) current without stopping anything on the machine.
///
/// On connect, when that file is an older cmux-tui than the app's bundled build (`cmux-tui remote
/// update-need`), the app's build is staged beside it as `cmux.staged`, checked against the same
/// pinned manifest as an install (``RemoteInstallPlan/stageOnly``). cmux-tui swaps it in at its
/// next session-server start (cmux-tui `staged_update.rs`); the script swaps it in at once only
/// when no session server runs the file. A file that is not cmux-tui (classic cmux's relay CLI)
/// is never touched. It holds no state: the check runs once per connect, and the machine's
/// install lock (beside the binary) keeps two Macs from staging at once.
public struct RemoteStaticInstallStager: Sendable {
    private let installer: RemoteInstaller
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "ssh.stage")

    /// - Parameter installer: The app's ``RemoteInstaller`` (its manifest and download cache).
    public init(installer: RemoteInstaller) {
        self.installer = installer
    }

    /// Stages the bundled build for `host`'s static install when it is older; `off` (the
    /// organization turned remote installs off) or a missing `binary` does nothing.
    ///
    /// - Returns: True when a newer build now waits as `cmux.staged` (a session server runs the
    ///   binary); false when nothing was staged or the build was swapped in at once.
    public func stageIfOlder(_ host: SSHHost, link: SSHMachineLink, binary: URL?,
                             environment: @Sendable () async -> [String: String], off: Bool) async -> Bool {
        let path = SSHHost.staticInstallBinary
        guard !off, host.remoteBinary != path, let binary, let commit = await BundledCmuxTUI.commit(binary: binary) else { return false }
        let env = await environment()
        guard let (probe, answer) = await host.updateCheck(remoteBinary: path, binary: binary, environment: env),
              answer.need == "older", let platform = await link.lastReport?.platform else { return false }
        var lockedPlan: RemoteInstallPlan?
        do {
            var plan = try await installer.plan(commit: commit, treeKey: BundledCmuxTUI.treeKey(binary: binary), platform: platform,
                                                remoteBinary: path)
            guard plan.commit != probe.buildIdentity?.lowercased() else { return false }
            plan.expectedRemoteIdentity = probe.buildIdentity
            lockedPlan = plan
            let swapped = try await installer.stage(plan, on: host, environment: env)
            await installer.releaseLock(plan, on: host, environment: env)
            logger.info("\(swapped ? "installed" : "staged", privacy: .public) cmux-tui \(plan.commit, privacy: .public) for \(path, privacy: .public) on \(host.destination.description, privacy: .public)")
            return !swapped
        } catch {
            if let lockedPlan { await installer.releaseLock(lockedPlan, on: host, environment: env) }
            logger.error("staging \(path, privacy: .public) on \(host.destination.description, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
