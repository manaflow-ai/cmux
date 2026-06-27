#if DEBUG
public import Foundation

/// The pure `workspace.remote.configure.request` debug-log line assembler.
///
/// This is the byte-faithful relocation of the former app-side `#if DEBUG`
/// string assembly inside `controlConfigureWorkspaceRemote`: it formats the
/// validated configuration and parsed params into the single instrumentation
/// line the app then hands to its `cmuxDebugLog` sink. It performs no I/O and
/// holds no app state — the caller owns the debug sink and the `#if DEBUG`
/// gate, exactly where the legacy code emitted the line.
///
/// Inputs are stdlib / Foundation `Sendable` values read off the validated
/// `WorkspaceRemoteConfiguration` (transport, ports, local socket) and the
/// parsed `ControlConfigureWorkspaceRemoteParams` (auto-connect, agent socket,
/// ssh options) so the formatter needs no `CmuxCore` edge. Gated to `#if DEBUG`,
/// matching the legacy block; it never compiles into release builds.
extension ControlCommandCoordinator {
    /// Assembles the `workspace.remote.configure.request` debug line.
    /// - Parameters:
    ///   - workspaceID: The target workspace id (only its 8-char prefix is logged).
    ///   - destination: The resolved SSH destination.
    ///   - transportRaw: The validated transport's `rawValue`.
    ///   - port: The validated SSH port, or `nil`.
    ///   - autoConnect: Whether the configure requested an immediate connect.
    ///   - relayPort: The validated relay port, or `nil`.
    ///   - localSocketPath: The validated local socket path, or `nil`.
    ///   - agentSocketPath: The parsed `ssh_auth_sock`, or `nil`.
    ///   - sshOptions: The parsed `ssh_options` list.
    /// - Returns: The single-line debug message.
    public func configureWorkspaceRemoteRequestLogLine(
        workspaceID: UUID,
        destination: String,
        transportRaw: String,
        port: Int?,
        autoConnect: Bool,
        relayPort: Int?,
        localSocketPath: String?,
        agentSocketPath: String?,
        sshOptions: [String]
    ) -> String {
        "workspace.remote.configure.request workspace=\(workspaceID.uuidString.prefix(8)) " +
        "target=\(destination) transport=\(transportRaw) port=\(port.map(String.init) ?? "nil") " +
        "autoConnect=\(autoConnect ? 1 : 0) relayPort=\(relayPort.map(String.init) ?? "nil") " +
        "localSocket=\(localSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? localSocketPath! : "nil") " +
        "sshAuthSock=\(agentSocketPath?.isEmpty == false ? 1 : 0) " +
        "sshOptions=\(sshOptions.joined(separator: "|"))"
    }
}
#endif
