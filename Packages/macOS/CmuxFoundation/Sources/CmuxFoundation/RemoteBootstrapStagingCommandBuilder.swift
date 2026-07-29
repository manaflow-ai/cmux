internal import Foundation

/// Stages a remote terminal bootstrap over an SSH management exec channel.
///
/// The potentially large bootstrap is streamed on standard input. Interactive
/// transports such as SSH or Mosh then execute only the small staged path.
public struct RemoteBootstrapStagingCommandBuilder: Sendable {
    private let installerSSHArguments: [String]
    private let destination: String
    private let remoteRelayPort: Int
    private let bootstrapScript: String

    /// Creates a bootstrap staging builder.
    ///
    /// - Parameters:
    ///   - installerSSHArguments: SSH executable and options, excluding destination.
    ///   - destination: SSH destination or host alias.
    ///   - remoteRelayPort: Valid relay namespace used for the staged path.
    ///   - bootstrapScript: Remote shell bootstrap containing optional cmux ID placeholders.
    public init?(
        installerSSHArguments: [String],
        destination: String,
        remoteRelayPort: Int,
        bootstrapScript: String
    ) {
        guard !installerSSHArguments.isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(remoteRelayPort),
              !bootstrapScript.isEmpty else {
            return nil
        }
        self.installerSSHArguments = installerSSHArguments
        self.destination = destination
        self.remoteRelayPort = remoteRelayPort
        self.bootstrapScript = bootstrapScript
    }

    /// Local shell code that substitutes runtime IDs and streams the bootstrap over SSH.
    public var preparationShellScript: String {
        let encodedBootstrapScript = Data(bootstrapScript.utf8).base64EncodedString()
        let installCommand = ([
            "/bin/sh",
            "-c",
            remoteInstallShellScript,
        ])
        .map(\.remoteCommandShellQuoted)
        .joined(separator: " ")
        let sshPrefix = installerSSHArguments
            .map(\.remoteCommandShellQuoted)
            .joined(separator: " ")
        return [
            "cmux_workspace_id=\"${CMUX_WORKSPACE_ID:-}\"",
            "cmux_surface_id=\"${CMUX_SURFACE_ID:-}\"",
            "cmux_remote_bootstrap_b64=\(encodedBootstrapScript.remoteCommandShellQuoted)",
            "cmux_remote_bootstrap=\"$(printf %s \"$cmux_remote_bootstrap_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_remote_bootstrap_b64\" | base64 -D 2>/dev/null)\"",
            "cmux_sed_escape() { printf '%s' \"$1\" | sed 's/[\\/&\\\\]/\\\\&/g'; }",
            "cmux_workspace_id_escaped=\"$(cmux_sed_escape \"$cmux_workspace_id\")\"",
            "cmux_surface_id_escaped=\"$(cmux_sed_escape \"$cmux_surface_id\")\"",
            "cmux_remote_bootstrap=\"$(printf '%s' \"$cmux_remote_bootstrap\" | sed \"s/__CMUX_WORKSPACE_ID__/$cmux_workspace_id_escaped/g; s/__CMUX_SURFACE_ID__/$cmux_surface_id_escaped/g\")\"",
            "printf '%s' \"$cmux_remote_bootstrap\" | command \(sshPrefix) -T \(destination.remoteCommandShellQuoted) \(installCommand.remoteCommandShellQuoted)",
            "cmux_remote_install_status=$?",
            "unset cmux_remote_bootstrap cmux_remote_bootstrap_b64 cmux_workspace_id cmux_surface_id cmux_workspace_id_escaped cmux_surface_id_escaped",
            "(exit \"$cmux_remote_install_status\")",
        ].joined(separator: "\n")
    }

    /// Small remote shell command that replaces the process with the staged bootstrap.
    public var remoteExecutionShellScript: String {
        "exec /bin/sh \"$HOME/.cmux/relay/\(remoteRelayPort).bootstrap.sh\""
    }

    /// Remote argv that executes the staged bootstrap.
    public var remoteExecutionCommandArguments: [String] {
        ["/bin/sh", "-c", remoteExecutionShellScript]
    }

    private var remoteInstallShellScript: String {
        [
            "set -eu",
            "umask 077",
            "cmux_bootstrap_path=\"$HOME/.cmux/relay/\(remoteRelayPort).bootstrap.sh\"",
            "mkdir -p \"$HOME/.cmux/relay\"",
            "cat > \"$cmux_bootstrap_path\"",
            "chmod 700 \"$cmux_bootstrap_path\" >/dev/null 2>&1 || true",
        ].joined(separator: "\n")
    }
}
