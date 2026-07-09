/// The fully-extracted `workspace.remote.configure` parameters, parsed once from
/// the command's typed `[String: JSONValue]` payload into a `Sendable` value the
/// app-resident witness feeds into `WorkspaceRemoteConfiguration.validated(...)`.
///
/// This is the byte-faithful relocation of the former app-side parameter block:
/// every field reproduces the exact coercion (and trimming / non-trimming) the
/// original `controlConfigureWorkspaceRemote` body performed inline, including
/// the `present` / `value` pairs the validator consumes for the range-checked
/// numeric params and the `daemon_websocket_headers` string-map. The pure domain
/// validation and `WorkspaceRemote*` assembly stay in `CmuxCore`; the app keeps
/// only workspace / owner resolution and the side effects.
///
/// `destination` is left optional: the witness still emits the verbatim
/// `invalid_params` "Missing destination" error when it is absent, matching the
/// original early guard.
public struct ControlConfigureWorkspaceRemoteParams: Sendable {
    /// `destination` (the required SSH target), read with the shared trimmed
    /// `string` accessor; `nil` triggers the witness's `invalid_params` guard.
    public var destination: String?

    /// `transport` (raw), trimmed and lowercased before the validator parses it.
    public var transportRaw: String?

    /// `auto_connect` (the configure boolean coercion), defaulting to `true`.
    public var autoConnect: Bool

    /// `port` presence and strict-int value.
    public var portPresent: Bool
    public var portValue: Int?

    /// `local_proxy_port` presence and strict-int value.
    public var localProxyPortPresent: Bool
    public var localProxyPortValue: Int?

    /// `relay_port` presence and strict-int value.
    public var relayPortPresent: Bool
    public var relayPortValue: Int?

    /// `identity_file`, trimmed.
    public var identityFile: String?

    /// `ssh_options` (string array, empties dropped), `[]` when absent.
    public var sshOptions: [String]

    /// `relay_id`, trimmed.
    public var relayID: String?

    /// `relay_token`, trimmed.
    public var relayToken: String?

    /// `foreground_auth_token`, trimmed.
    public var foregroundAuthToken: String?

    /// `local_socket_path`, read raw (NOT trimmed — matches the original).
    public var localSocketPath: String?

    /// `managed_cloud_vm_id`, trimmed.
    public var managedCloudVMID: String?

    /// Whether `ssh_auth_sock` was present and non-null.
    public var hasExplicitAgentSocketPath: Bool

    /// `ssh_auth_sock`, trimmed.
    public var agentSocketPath: String?

    /// `terminal_startup_command`, trimmed.
    public var terminalStartupCommand: String?

    /// Whether `persistent_daemon_slot` was present and non-null.
    public var persistentDaemonSlotPresent: Bool

    /// `persistent_daemon_slot` (raw value), trimmed.
    public var persistentDaemonSlotRaw: String?

    /// `daemon_websocket_url`, trimmed.
    public var daemonWebSocketURL: String?

    /// `daemon_websocket_token`, trimmed.
    public var daemonWebSocketToken: String?

    /// `daemon_websocket_session_id`, trimmed.
    public var daemonWebSocketSessionID: String?

    /// `daemon_websocket_expires_at_unix`, coerced via the configure expiry rule.
    public var daemonWebSocketExpiresAtUnix: Int64

    /// `daemon_websocket_headers`: the object's string-valued entries.
    public var daemonWebSocketHeaders: [String: String]

    /// Whether `preserve_after_terminal_exit` was present and non-null.
    public var preservePresent: Bool

    /// `preserve_after_terminal_exit` (configure boolean coercion).
    public var preserveValue: Bool?

    /// `skip_daemon_bootstrap` (configure boolean coercion), defaulting to `false`.
    public var skipDaemonBootstrap: Bool

    public init(
        destination: String?,
        transportRaw: String?,
        autoConnect: Bool,
        portPresent: Bool,
        portValue: Int?,
        localProxyPortPresent: Bool,
        localProxyPortValue: Int?,
        relayPortPresent: Bool,
        relayPortValue: Int?,
        identityFile: String?,
        sshOptions: [String],
        relayID: String?,
        relayToken: String?,
        foregroundAuthToken: String?,
        localSocketPath: String?,
        managedCloudVMID: String?,
        hasExplicitAgentSocketPath: Bool,
        agentSocketPath: String?,
        terminalStartupCommand: String?,
        persistentDaemonSlotPresent: Bool,
        persistentDaemonSlotRaw: String?,
        daemonWebSocketURL: String?,
        daemonWebSocketToken: String?,
        daemonWebSocketSessionID: String?,
        daemonWebSocketExpiresAtUnix: Int64,
        daemonWebSocketHeaders: [String: String],
        preservePresent: Bool,
        preserveValue: Bool?,
        skipDaemonBootstrap: Bool
    ) {
        self.destination = destination
        self.transportRaw = transportRaw
        self.autoConnect = autoConnect
        self.portPresent = portPresent
        self.portValue = portValue
        self.localProxyPortPresent = localProxyPortPresent
        self.localProxyPortValue = localProxyPortValue
        self.relayPortPresent = relayPortPresent
        self.relayPortValue = relayPortValue
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.relayID = relayID
        self.relayToken = relayToken
        self.foregroundAuthToken = foregroundAuthToken
        self.localSocketPath = localSocketPath
        self.managedCloudVMID = managedCloudVMID
        self.hasExplicitAgentSocketPath = hasExplicitAgentSocketPath
        self.agentSocketPath = agentSocketPath
        self.terminalStartupCommand = terminalStartupCommand
        self.persistentDaemonSlotPresent = persistentDaemonSlotPresent
        self.persistentDaemonSlotRaw = persistentDaemonSlotRaw
        self.daemonWebSocketURL = daemonWebSocketURL
        self.daemonWebSocketToken = daemonWebSocketToken
        self.daemonWebSocketSessionID = daemonWebSocketSessionID
        self.daemonWebSocketExpiresAtUnix = daemonWebSocketExpiresAtUnix
        self.daemonWebSocketHeaders = daemonWebSocketHeaders
        self.preservePresent = preservePresent
        self.preserveValue = preserveValue
        self.skipDaemonBootstrap = skipDaemonBootstrap
    }
}
