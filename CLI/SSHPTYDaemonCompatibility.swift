import Foundation

/// Admits an SSH PTY only when the daemon identifies the client's release.
struct SSHPTYDaemonCompatibility {
    let clientVersion: String

    func validate(_ daemonVersion: String?) throws {
        guard let daemonVersion, matches(daemonVersion) else {
            throw CLIError(message: String(
                localized: "cli.sshPtyAttach.incompatibleDaemon",
                defaultValue: "SSH attach stopped because the remote daemon version does not match this cmux client. Install a cmux release with its matching remote daemon, then reconnect the workspace. Do not substitute a daemon from an older release.",
                bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
            ))
        }
    }

    private func matches(_ daemonVersion: String) -> Bool {
        guard !clientVersion.isEmpty, clientVersion != "dev" else { return false }
        if daemonVersion == clientVersion { return true }
#if DEBUG
        // Local daemon builds append their source hash to this same release.
        let prefix = clientVersion + "-dev-"
        guard daemonVersion.hasPrefix(prefix) else { return false }
        let fingerprint = daemonVersion.dropFirst(prefix.count)
        return fingerprint.count == 12 && fingerprint.allSatisfy { "0123456789abcdef".contains($0) }
#else
        return false
#endif
    }
}
