public import Foundation

extension WorkspaceRemoteConfiguration {
    /// Validates the control-plane parameters for `workspace.remote.configure`
    /// and assembles a ``WorkspaceRemoteConfiguration``.
    ///
    /// This performs only the pure domain rules from the original app-target
    /// command body: the port / `relay_port` / `local_proxy_port` 1-65535 range
    /// checks, the `relay_token` 64-lowercase-hex format, the
    /// `persistent_daemon_slot` character-set regex and default, the
    /// daemon-WebSocket endpoint triple, the preserve / persistent coupling, the
    /// transport parse, and the final value assembly (with the empty-string to
    /// `nil` normalizations). Parameter extraction (the app's `v2*` param
    /// helpers) and workspace / owner resolution stay app-side; the extracted
    /// values are passed in here.
    ///
    /// Validation runs in the same order as the original body so the
    /// first-failing rule, and therefore the returned message, is byte-identical.
    ///
    /// - Returns: `.success` with the assembled configuration, or `.failure`
    ///   carrying the verbatim `invalid_params` message.
    public static func validated(
        transportRaw: String?,
        destination: String,
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
        persistentDaemonSlotValue: String?,
        daemonWebSocketURL: String?,
        daemonWebSocketToken: String?,
        daemonWebSocketSessionID: String?,
        daemonWebSocketExpiresAtUnix: Int64,
        daemonWebSocketHeaders: [String: String],
        preservePresent: Bool,
        preserveValue: Bool?,
        skipDaemonBootstrap: Bool,
        workspaceID: UUID
    ) -> Result<WorkspaceRemoteConfiguration, WorkspaceRemoteConfigurationValidationError> {
        var sshPort: Int?
        if portPresent {
            guard let parsedPort = portValue,
                  parsedPort > 0,
                  parsedPort <= 65535 else {
                return .failure(.invalidParameter("port must be 1-65535"))
            }
            sshPort = parsedPort
        }

        var localProxyPort: Int?
        if localProxyPortPresent {
            guard let parsedLocalProxyPort = localProxyPortValue,
                  parsedLocalProxyPort > 0,
                  parsedLocalProxyPort <= 65535 else {
                return .failure(.invalidParameter("local_proxy_port must be 1-65535"))
            }
            localProxyPort = parsedLocalProxyPort
        }

        let transport = WorkspaceRemoteTransport(rawValue: transportRaw ?? "") ?? .ssh

        var relayPort: Int?
        if relayPortPresent {
            guard let parsedRelayPort = relayPortValue,
                  parsedRelayPort > 0,
                  parsedRelayPort <= 65535 else {
                return .failure(.invalidParameter("relay_port must be 1-65535"))
            }
            relayPort = parsedRelayPort
        }

        var persistentDaemonSlot = persistentDaemonSlotValue
        if persistentDaemonSlotPresent {
            guard let persistentDaemonSlot,
                  !persistentDaemonSlot.isEmpty,
                  persistentDaemonSlot.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  persistentDaemonSlot != ".",
                  persistentDaemonSlot != ".." else {
                return .failure(.invalidParameter(
                    "persistent_daemon_slot must contain only letters, numbers, '.', '_' or '-'"
                ))
            }
        }

        let daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint?
        if let daemonWebSocketURL,
           !daemonWebSocketURL.isEmpty,
           let daemonWebSocketToken,
           !daemonWebSocketToken.isEmpty,
           let daemonWebSocketSessionID,
           !daemonWebSocketSessionID.isEmpty {
            daemonWebSocketEndpoint = WorkspaceRemoteWebSocketDaemonEndpoint(
                url: daemonWebSocketURL,
                headers: daemonWebSocketHeaders,
                token: daemonWebSocketToken,
                sessionId: daemonWebSocketSessionID,
                expiresAtUnix: daemonWebSocketExpiresAtUnix
            )
        } else {
            daemonWebSocketEndpoint = nil
        }

        let preserveAfterTerminalExit = preserveValue ?? false
        if preservePresent, preserveValue == nil {
            return .failure(.invalidParameter("preserve_after_terminal_exit must be a boolean"))
        }

        if persistentDaemonSlot != nil, !preserveAfterTerminalExit {
            return .failure(.invalidParameter(
                "preserve_after_terminal_exit is required when persistent_daemon_slot is set"
            ))
        }
        if preserveAfterTerminalExit,
           transport == .ssh,
           !skipDaemonBootstrap,
           daemonWebSocketEndpoint == nil,
           persistentDaemonSlot == nil {
            persistentDaemonSlot = "ssh-\(workspaceID.uuidString.lowercased())"
        }
        if relayPort != nil {
            guard let relayID, !relayID.isEmpty else {
                return .failure(.invalidParameter("relay_id is required when relay_port is set"))
            }
            guard let relayToken,
                  relayToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                return .failure(.invalidParameter(
                    "relay_token must be 64 lowercase hex characters when relay_port is set"
                ))
            }
        }

        let config = WorkspaceRemoteConfiguration(
            transport: transport,
            destination: destination,
            port: sshPort,
            identityFile: identityFile?.isEmpty == true ? nil : identityFile,
            sshOptions: sshOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID?.isEmpty == true ? nil : relayID,
            relayToken: relayToken?.isEmpty == true ? nil : relayToken,
            localSocketPath: localSocketPath,
            managedCloudVMID: managedCloudVMID?.isEmpty == true ? nil : managedCloudVMID,
            terminalStartupCommand: terminalStartupCommand?.isEmpty == true ? nil : terminalStartupCommand,
            foregroundAuthToken: foregroundAuthToken?.isEmpty == true ? nil : foregroundAuthToken,
            agentSocketPath: WorkspaceRemoteConfiguration.resolvedAgentSocketPath(
                sshOptions: sshOptions,
                explicitAgentSocketPath: agentSocketPath,
                explicitAgentSocketPathIsSet: hasExplicitAgentSocketPath
            ),
            daemonWebSocketEndpoint: daemonWebSocketEndpoint,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot?.isEmpty == true ? nil : persistentDaemonSlot,
            skipDaemonBootstrap: skipDaemonBootstrap
        )
        return .success(config)
    }
}
