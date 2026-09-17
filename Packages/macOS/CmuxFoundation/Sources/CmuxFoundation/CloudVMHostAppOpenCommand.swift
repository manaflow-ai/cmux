import Foundation

/// Shared shape of the `vm.open_local` control-socket method, which asks the
/// Mac app to run a Cloud VM attach **on the Mac** instead of in the calling
/// CLI process.
///
/// A `cmux` CLI invoked inside a remote workspace reaches the app through the
/// remote CLI relay, so its socket RPCs land on the Mac while the process
/// itself runs on the remote host. Every Cloud VM attach path builds a shell
/// command out of process-local values (the CLI's own executable path, its
/// socket path, credential files it writes next to itself) and hands that
/// command to a Mac-hosted pane. Those paths do not exist on the Mac, so the
/// workspace opens onto a dead pane and the user falls back to
/// `cmux ssh-tmux`. Delegating the attach to the app moves the whole
/// path-sensitive step onto the machine that will execute it.
///
/// The relayed caller never supplies argv. It names *which* attach it wants;
/// the app builds the argument vector from this fixed set of shapes and
/// rejects a VM id that is not an opaque identifier.
public enum CloudVMHostAppOpenCommand: Equatable, Sendable {
    /// Open (or reattach to) the single persistent Base workspace.
    case base
    /// Attach to a specific Cloud VM over the managed transport.
    case shell(vmID: String)
    /// Attach to a specific Cloud VM over foreground SSH (`cmux vm ssh <id>`).
    case ssh(vmID: String)

    public static let method = "vm.open_local"
    public static let vmIDParameterKey = "id"
    public static let forceSSHParameterKey = "force_ssh"

    /// Builds the request parameters the relayed CLI sends to the app.
    public var socketParameters: [String: Any] {
        switch self {
        case .base:
            return [:]
        case .shell(let vmID):
            return [Self.vmIDParameterKey: vmID]
        case .ssh(let vmID):
            return [Self.vmIDParameterKey: vmID, Self.forceSSHParameterKey: true]
        }
    }

    /// Reconstructs the command from received parameters, rejecting a VM id
    /// that could not have come from the control plane.
    ///
    /// Returns `nil` when the id is present but malformed, so the app answers
    /// `invalid_params` rather than shelling out with attacker-chosen text.
    public static func from(socketParameters params: [String: Any]) -> CloudVMHostAppOpenCommand? {
        guard let rawID = params[vmIDParameterKey] else { return .base }
        guard let vmID = rawID as? String else { return nil }
        let trimmed = vmID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidVMID(trimmed) else { return nil }
        let forceSSH = (params[forceSSHParameterKey] as? Bool)
            ?? ((params[forceSSHParameterKey] as? NSNumber)?.boolValue ?? false)
        return forceSSH ? .ssh(vmID: trimmed) : .shell(vmID: trimmed)
    }

    /// The `cmux` argument vector the app runs locally for this command.
    ///
    /// `.base` is absent: the app opens Base through its own workspace-owning
    /// action (the same one the New Workspace menu uses) so the loading panel
    /// and pinning behave identically for both entrypoints.
    public var cliArguments: [String]? {
        switch self {
        case .base:
            return nil
        case .shell(let vmID):
            return ["vm", "shell", vmID]
        case .ssh(let vmID):
            return ["vm", "ssh", vmID]
        }
    }

    /// Cloud VM ids are opaque control-plane identifiers. Restricting them to
    /// this alphabet keeps every byte that reaches argv non-shell-significant.
    public static func isValidVMID(_ value: String) -> Bool {
        // A leading `-` would land in argv as a flag rather than as the
        // positional id, so it is rejected along with shell-significant bytes.
        guard !value.isEmpty, value.count <= 128, !value.hasPrefix("-") else { return false }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }
}
