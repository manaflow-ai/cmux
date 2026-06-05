import Darwin
import Foundation
import CmuxFoundation
#if canImport(Security)
import Security
#endif

private enum WorkspaceRemoteSSHOptionFilter {
    private static let transientControlSocketKeys: Set<String> = [
        "controlmaster",
        "controlpath",
        "controlpersist",
    ]

    static func durableOptions(_ options: [String]) -> [String] {
        filteredOptions(options, droppingKeys: transientControlSocketKeys)
    }

    static func forkedWorkspaceOptions(_ options: [String]) -> [String] {
        durableOptions(options)
    }

    static func trimmedOptions(_ options: [String]) -> [String] {
        filteredOptions(options, droppingKeys: [])
    }

    private static func filteredOptions(_ options: [String], droppingKeys keys: Set<String>) -> [String] {
        options.compactMap { option in
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.filter { option in
            guard let key = SSHAgentSocketResolver().optionKey(option) else { return true }
            return !keys.contains(key)
        }
    }

    static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedPersistentDaemonSlot(_ value: String?) -> String? {
        guard let slot = normalizedOptional(value),
              slot != ".",
              slot != "..",
              slot.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return slot
    }

    static func normalizedIdentityPath(_ value: String?) -> String? {
        guard let trimmed = normalizedOptional(value) else { return nil }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return normalizedOptional((trimmed as NSString).expandingTildeInPath) ?? trimmed
    }

    /// Normalizes an SSH agent socket path and expands `~` so environment injection receives a usable path.
    static func normalizedAgentSocketPath(_ value: String?) -> String? {
        SSHAgentSocketResolver().normalizedAgentSocketPath(value)
    }

    /// Returns a normalized agent socket path only when it currently exists.
    static func existingAgentSocketPath(_ value: String?) -> String? {
        guard let path = normalizedAgentSocketPath(value),
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    static func hasOptionKey(_ options: [String], key: String) -> Bool {
        SSHAgentSocketResolver().hasOptionKey(options, key: key)
    }

    /// Resolves a durable `ForwardAgent` SSH option into the current local agent socket path, when one is usable.
    static func sshAgentSocketPath(for options: [String]) -> String? {
        SSHAgentSocketResolver().agentSocketPath(for: options)
    }
}

nonisolated enum WorkspaceRemoteTransport: String, Codable, Equatable, Sendable {
    case ssh
    case websocket
}

nonisolated struct SessionRemoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    var transport: WorkspaceRemoteTransport
    var destination: String
    var port: Int?
    var identityFile: String?
    var sshOptions: [String]
    var preserveAfterTerminalExit: Bool?
    var skipDaemonBootstrap: Bool?
    var relayPort: Int? = nil
    var persistentDaemonSlot: String? = nil
}

struct WorkspaceRemoteWebSocketDaemonEndpoint: Equatable {
    let url: String
    let headers: [String: String]
    let token: String
    let sessionId: String
    let expiresAtUnix: Int64

    var proxyBrokerKeyComponent: String {
        [
            url.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionId.trimmingCharacters(in: .whitespacesAndNewlines),
            String(expiresAtUnix),
        ]
            .joined(separator: "\u{1f}")
    }
}

nonisolated enum SSHPTYAttachStartupCommandBuilder {
    struct ForegroundAuth {
        let destination: String
        let port: Int?
        let identityFile: String?
        let sshOptions: [String]
        let token: String
    }

    static func command(
        sessionID: String? = nil,
        foregroundAuth: ForegroundAuth? = nil,
        remoteCommand: String? = nil,
        requireExisting: Bool = true
    ) -> String {
        var lines = [
            "cmux_ssh_attach_cli=\"${CMUX_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$cmux_ssh_attach_cli\" ] || [ ! -x \"$cmux_ssh_attach_cli\" ]; then cmux_ssh_attach_cli=\"$(command -v cmux 2>/dev/null || true)\"; fi",
            "if [ -z \"$cmux_ssh_attach_cli\" ]; then printf '%s\\n' '[cmux] bundled CLI not found for SSH PTY attach.' >&2; exit 127; fi",
            "if [ -z \"${CMUX_SOCKET_PATH:-}\" ]; then printf '%s\\n' '[cmux] required configuration missing for SSH PTY attach.' >&2; exit 1; fi",
            "if [ -z \"${CMUX_WORKSPACE_ID:-}\" ]; then printf '%s\\n' '[cmux] required workspace context missing for SSH PTY attach.' >&2; exit 1; fi",
        ]
        if let sessionID = normalized(sessionID) {
            lines.append("cmux_ssh_attach_session_id=\(shellQuote(sessionID))")
        } else {
            lines += [
                "if [ -z \"${CMUX_SURFACE_ID:-}\" ]; then printf '%s\\n' '[cmux] required terminal context missing for SSH PTY attach.' >&2; exit 1; fi",
                "cmux_ssh_attach_session_id=\"ssh-$CMUX_WORKSPACE_ID-$CMUX_SURFACE_ID\"",
            ]
        }
        if let foregroundAuth {
            lines += foregroundAuthLines(foregroundAuth)
        }
        let requireExistingFlag = requireExisting ? " --require-existing" : ""
        let commandB64Flag = normalized(remoteCommand).map {
            " --command-b64 \(shellQuote(Data($0.utf8).base64EncodedString()))"
        } ?? ""
        let attachCommand = "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" ssh-pty-attach --wait\(requireExistingFlag) --workspace \"$CMUX_WORKSPACE_ID\" --session-id \"$cmux_ssh_attach_session_id\" --attachment-id \"${CMUX_SURFACE_ID:-}\"\(commandB64Flag)"
        lines += retryingAttachLines(command: attachCommand)
        return "/bin/sh -c \(shellQuote(lines.joined(separator: "\n")))"
    }

    static func restoredRemoteShellCommand(relayPort: Int) -> String {
        RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: relayPort,
            shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(),
            bundledZshIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                named: "cmux-zsh-integration.zsh"
            ),
            bundledBashIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                named: "cmux-bash-integration.bash"
            )
        )
    }

    private static func retryingAttachLines(command: String) -> [String] {
        [
            "cmux_ssh_attach_reconnect_limit=\"${CMUX_SSH_RECONNECT_LIMIT:-20}\"",
            "case \"$cmux_ssh_attach_reconnect_limit\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_limit=20 ;; esac",
            "cmux_ssh_attach_reconnect_delay=\"${CMUX_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$cmux_ssh_attach_reconnect_delay\" in ''|*[!0-9]*) cmux_ssh_attach_reconnect_delay=2 ;; esac",
            "cmux_ssh_attach_retry=0",
            "while :; do",
            "  \(command)",
            "  cmux_ssh_attach_status=$?",
            "  case \"$cmux_ssh_attach_status\" in 254|255) ;; *) exit \"$cmux_ssh_attach_status\" ;; esac",
            "  if [ \"$cmux_ssh_attach_retry\" -ge \"$cmux_ssh_attach_reconnect_limit\" ]; then exit \"$cmux_ssh_attach_status\"; fi",
            "  cmux_ssh_attach_retry=$((cmux_ssh_attach_retry + 1))",
            "  if [ -t 2 ]; then printf '\\n\\033[33m[cmux] remote PTY bridge closed; reattaching (attempt %s/%s).\\033[0m\\n' \"$cmux_ssh_attach_retry\" \"$cmux_ssh_attach_reconnect_limit\" >&2 || true; fi",
            "  if [ \"$cmux_ssh_attach_reconnect_delay\" -gt 0 ]; then sleep \"$cmux_ssh_attach_reconnect_delay\"; fi",
            "done",
        ]
    }

    private static func foregroundAuthLines(_ auth: ForegroundAuth) -> [String] {
        let sshCommand = sshForegroundAuthCommand(auth)
        let quotedToken = shellQuote(auth.token)
        return [
            "\(sshCommand)",
            "cmux_ssh_auth_status=$?",
            "if [ \"$cmux_ssh_auth_status\" -ne 0 ]; then exit \"$cmux_ssh_auth_status\"; fi",
            "cmux_ssh_auth_token=\(quotedToken)",
            "cmux_ssh_auth_payload=\"{\\\"workspace_id\\\":\\\"$CMUX_WORKSPACE_ID\\\",\\\"foreground_auth_token\\\":\\\"$cmux_ssh_auth_token\\\"}\"",
            "\"$cmux_ssh_attach_cli\" --socket \"$CMUX_SOCKET_PATH\" rpc workspace.remote.foreground_auth_ready \"$cmux_ssh_auth_payload\" >/dev/null 2>&1 || true",
            "unset cmux_ssh_auth_payload cmux_ssh_auth_status cmux_ssh_auth_token",
        ]
    }

    private static func sshForegroundAuthCommand(_ auth: ForegroundAuth) -> String {
        var arguments = ["ssh"]
        let options = sshOptionsWithRestoreControlDefaults(auth.sshOptions)
        if !hasSSHOptionKey(options, key: "ConnectTimeout") {
            arguments += ["-o", "ConnectTimeout=6"]
        }
        if !hasSSHOptionKey(options, key: "ServerAliveInterval") {
            arguments += ["-o", "ServerAliveInterval=20"]
        }
        if !hasSSHOptionKey(options, key: "ServerAliveCountMax") {
            arguments += ["-o", "ServerAliveCountMax=2"]
        }
        if let port = auth.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = normalized(auth.identityFile) {
            arguments += ["-i", identityFile]
        }
        for option in options {
            arguments += ["-o", option]
        }
        arguments += ["-T", auth.destination, "true"]
        return arguments.map(shellQuote).joined(separator: " ")
    }

    static func sshOptionsWithRestoreControlDefaults(_ options: [String], relayPort: Int? = nil) -> [String] {
        var merged = options.compactMap(normalized)
        let controlMaster = sshOptionValue(named: "ControlMaster", in: merged)
        let controlMasterDisabled = sshOptionValueIsDisabled(controlMaster)
        if controlMaster == nil {
            merged.append("ControlMaster=auto")
        }
        if !controlMasterDisabled {
            if !hasSSHOptionKey(merged, key: "ControlPersist") {
                merged.append("ControlPersist=600")
            }
            if !hasSSHOptionKey(merged, key: "ControlPath") {
                merged.append("ControlPath=\(restoreControlPathTemplate(relayPort: relayPort))")
            }
        }
        return merged
    }

    private static func restoreControlPathTemplate(relayPort: Int?) -> String {
        if let relayPort, relayPort > 0 {
            return "/tmp/cmux-ssh-\(getuid())-\(relayPort)-%C"
        }
        return "/tmp/cmux-ssh-\(getuid())-%C"
    }

    static func sshOptionsSupportReusableForegroundAuth(_ options: [String]) -> Bool {
        guard !hasSSHOptionKey(options, key: "LocalCommand"),
              !hasSSHOptionKey(options, key: "PermitLocalCommand") else {
            return false
        }

        guard let controlPath = sshOptionValue(named: "ControlPath", in: options),
              !controlPath.isEmpty,
              controlPath.lowercased() != "none" else {
            return false
        }

        if sshOptionValueIsDisabled(sshOptionValue(named: "ControlMaster", in: options)) {
            return false
        }

        return !sshOptionValueIsDisabled(
            sshOptionValue(named: "ControlPersist", in: options),
            zeroIsDisabled: false
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        SSHAgentSocketResolver().hasOptionKey(options, key: key)
    }

    private static func sshOptionValue(named name: String, in options: [String]) -> String? {
        SSHAgentSocketResolver().optionValue(named: name, in: options)
    }

    private static func sshOptionValueIsDisabled(_ rawValue: String?, zeroIsDisabled: Bool = true) -> Bool {
        guard let normalized = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["no", "false", "off"].contains(normalized) || (zeroIsDisabled && normalized == "0")
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

struct WorkspaceRemoteConfiguration: Equatable {
    let transport: WorkspaceRemoteTransport
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
    let localProxyPort: Int?
    let relayPort: Int?
    let relayID: String?
    let relayToken: String?
    let localSocketPath: String?
    let terminalStartupCommand: String?
    let foregroundAuthToken: String?
    let agentSocketPath: String?
    let daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint?
    let preserveAfterTerminalExit: Bool
    let persistentDaemonSlot: String?
    /// True for cloud-VM remotes (Freestyle snapshots) where cmuxd-remote is pre-baked in
    /// the image and started via systemd. Skip the upload+exec bootstrap entirely and synthesize
    /// a `DaemonHello`. Reverse-relay still stays off, but SSH-backed VM workspaces can talk to
    /// the baked daemon through an SSH local forward to `/run/cmuxd-remote.sock`.
    let skipDaemonBootstrap: Bool

    init(
        transport: WorkspaceRemoteTransport = .ssh,
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        localProxyPort: Int?,
        relayPort: Int?,
        relayID: String?,
        relayToken: String?,
        localSocketPath: String?,
        terminalStartupCommand: String?,
        foregroundAuthToken: String? = nil,
        agentSocketPath: String? = nil,
        daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint? = nil,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil,
        skipDaemonBootstrap: Bool = false
    ) {
        self.transport = transport
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.localProxyPort = localProxyPort
        self.relayPort = relayPort
        self.relayID = relayID
        self.relayToken = relayToken
        self.localSocketPath = localSocketPath
        self.terminalStartupCommand = terminalStartupCommand
        self.foregroundAuthToken = foregroundAuthToken
        self.agentSocketPath = WorkspaceRemoteSSHOptionFilter.normalizedAgentSocketPath(agentSocketPath)
        self.daemonWebSocketEndpoint = daemonWebSocketEndpoint
        self.preserveAfterTerminalExit = preserveAfterTerminalExit
        self.persistentDaemonSlot = preserveAfterTerminalExit
            ? WorkspaceRemoteSSHOptionFilter.normalizedPersistentDaemonSlot(persistentDaemonSlot)
            : nil
        self.skipDaemonBootstrap = skipDaemonBootstrap
    }

    /// Resolves the SSH agent socket to use for a remote configuration from an explicit socket or durable options.
    static func resolvedAgentSocketPath(
        sshOptions: [String],
        explicitAgentSocketPath: String? = nil,
        explicitAgentSocketPathIsSet: Bool = false
    ) -> String? {
        if explicitAgentSocketPathIsSet {
            return WorkspaceRemoteSSHOptionFilter.existingAgentSocketPath(explicitAgentSocketPath)
        }
        return WorkspaceRemoteSSHOptionFilter.existingAgentSocketPath(explicitAgentSocketPath)
            ?? WorkspaceRemoteSSHOptionFilter.existingAgentSocketPath(
                WorkspaceRemoteSSHOptionFilter.sshAgentSocketPath(for: sshOptions)
            )
    }

    var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }

    var proxyBrokerTransportKey: String {
        let normalizedTransport = transport.rawValue
        let normalizedBootstrapMode = skipDaemonBootstrap ? "vm-baked" : "bootstrap"
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.map(String.init) ?? ""
        let normalizedIdentity = WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(identityFile) ?? ""
        let normalizedLocalProxyPort = localProxyPort.map(String.init) ?? ""
        let normalizedOptions = Self.proxyBrokerSSHOptions(sshOptions).joined(separator: "\u{1f}")
        let normalizedWebSocketDaemon = daemonWebSocketEndpoint?.proxyBrokerKeyComponent ?? ""
        let normalizedRequiredCapabilities = preserveAfterTerminalExit ? "pty.session" : ""
        let normalizedPersistentDaemonSlot = persistentDaemonSlot ?? ""
        return [
            normalizedTransport,
            normalizedBootstrapMode,
            normalizedDestination,
            normalizedPort,
            normalizedIdentity,
            normalizedOptions,
            normalizedLocalProxyPort,
            normalizedWebSocketDaemon,
            normalizedRequiredCapabilities,
            normalizedPersistentDaemonSlot,
        ]
            .joined(separator: "\u{1e}")
    }

    private static func proxyBrokerSSHOptions(_ options: [String]) -> [String] {
        WorkspaceRemoteSSHOptionFilter.durableOptions(options)
    }

    func hasSamePersistentPTYIdentity(as other: WorkspaceRemoteConfiguration) -> Bool {
        guard preserveAfterTerminalExit,
              other.preserveAfterTerminalExit,
              let persistentDaemonSlot,
              persistentDaemonSlot == other.persistentDaemonSlot else {
            return false
        }

        return transport == other.transport
            && skipDaemonBootstrap == other.skipDaemonBootstrap
            && destination.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            && port == other.port
            && relayPort == other.relayPort
            && WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(identityFile)
                == WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(other.identityFile)
            && Self.proxyBrokerSSHOptions(sshOptions) == Self.proxyBrokerSSHOptions(other.sshOptions)
            && daemonWebSocketEndpoint?.proxyBrokerKeyComponent == other.daemonWebSocketEndpoint?.proxyBrokerKeyComponent
    }
}

extension SessionRemoteWorkspaceSnapshot {
    func workspaceConfiguration(
        localSocketPath: String? = nil,
        allowPersistentPTYRestore: Bool = true,
        preserveSSHOptions: Bool = false,
        agentSocketPath overrideAgentSocketPath: String? = nil
    ) -> WorkspaceRemoteConfiguration? {
        guard transport == .ssh else { return nil }
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty else { return nil }
        let normalizedPort = port.flatMap { port in
            (1...65535).contains(port) ? port : nil
        }

        let normalizedPersistentDaemonSlot = WorkspaceRemoteSSHOptionFilter.normalizedPersistentDaemonSlot(persistentDaemonSlot)
        let normalizedLocalSocketPath = WorkspaceRemoteSSHOptionFilter.normalizedOptional(localSocketPath)
        let normalizedRelayPort = relayPort.flatMap { port in
            (1...65535).contains(port) ? port : nil
        }
        let preservedOptions = preserveSSHOptions
            ? WorkspaceRemoteSSHOptionFilter.trimmedOptions(sshOptions)
            : Self.normalizedSSHOptions(sshOptions)
        let optionsWithRestoreControlDefaults = SSHPTYAttachStartupCommandBuilder.sshOptionsWithRestoreControlDefaults(
            preservedOptions,
            relayPort: normalizedRelayPort
        )
        let fallbackSSHOptions = preserveSSHOptions
            ? Self.normalizedSSHOptions(preservedOptions)
            : preservedOptions
        let preservePTYSession =
            allowPersistentPTYRestore &&
            preserveAfterTerminalExit == true &&
            skipDaemonBootstrap != true &&
            normalizedPersistentDaemonSlot != nil &&
            normalizedLocalSocketPath != nil &&
            normalizedRelayPort != nil &&
            SSHPTYAttachStartupCommandBuilder.sshOptionsSupportReusableForegroundAuth(optionsWithRestoreControlDefaults)
        let restoredSSHOptions = preservePTYSession ? optionsWithRestoreControlDefaults : fallbackSSHOptions
        let foregroundAuthToken = preservePTYSession ? UUID().uuidString.lowercased() : nil
        let foregroundAuth = foregroundAuthToken.map {
            SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: normalizedDestination,
                port: normalizedPort,
                identityFile: Self.normalizedIdentityPath(identityFile),
                sshOptions: restoredSSHOptions,
                token: $0
            )
        }
        let restoredRelayID = preservePTYSession
            ? UUID().uuidString.lowercased()
            : nil
        let restoredRelayToken = preservePTYSession
            ? Self.restoreRelayTokenHex()
            : nil
        let restoredRemoteShellCommand = preservePTYSession
            ? normalizedRelayPort.map(SSHPTYAttachStartupCommandBuilder.restoredRemoteShellCommand(relayPort:))
            : nil
        return WorkspaceRemoteConfiguration(
            transport: transport,
            destination: normalizedDestination,
            port: normalizedPort,
            identityFile: Self.normalizedIdentityPath(identityFile),
            sshOptions: restoredSSHOptions,
            localProxyPort: nil,
            relayPort: preservePTYSession ? normalizedRelayPort : nil,
            relayID: restoredRelayID,
            relayToken: restoredRelayToken,
            localSocketPath: preservePTYSession ? normalizedLocalSocketPath : nil,
            terminalStartupCommand: preservePTYSession
                ? SSHPTYAttachStartupCommandBuilder.command(
                    foregroundAuth: foregroundAuth,
                    remoteCommand: restoredRemoteShellCommand,
                    // Restored panels get explicit require-existing attach commands with their
                    // persisted session IDs; this workspace default is for new panes.
                    requireExisting: false
                )
                : sshReconnectCommand(
                    destination: normalizedDestination,
                    port: normalizedPort,
                    sshOptions: restoredSSHOptions
                ),
            foregroundAuthToken: foregroundAuthToken,
            agentSocketPath: WorkspaceRemoteConfiguration.resolvedAgentSocketPath(
                sshOptions: restoredSSHOptions,
                explicitAgentSocketPath: overrideAgentSocketPath
            ),
            daemonWebSocketEndpoint: nil,
            preserveAfterTerminalExit: preservePTYSession,
            persistentDaemonSlot: preservePTYSession ? normalizedPersistentDaemonSlot : nil,
            skipDaemonBootstrap: skipDaemonBootstrap == true
        )
    }

    private static func restoreRelayTokenHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
#if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
#endif
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private func sshReconnectCommand(
        destination normalizedDestination: String,
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String]? = nil
    ) -> String? {
        var arguments = ["ssh"]
        if let normalizedPort {
            arguments += ["-p", String(normalizedPort)]
        }
        if let identityFile = Self.normalizedIdentityPath(identityFile) {
            arguments += ["-i", identityFile]
        }
        let normalizedOptions = reconnectSSHOptions ?? Self.normalizedSSHOptions(sshOptions)
        for option in normalizedOptions {
            arguments += ["-o", option]
        }
        if !Self.hasSSHOptionKey(normalizedOptions, key: "RequestTTY") {
            arguments.append("-tt")
        }
        arguments.append(normalizedDestination)
        return arguments.map(Self.shellQuote).joined(separator: " ")
    }

    private static func normalizedIdentityPath(_ value: String?) -> String? {
        WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(value)
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        WorkspaceRemoteSSHOptionFilter.durableOptions(options)
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        WorkspaceRemoteSSHOptionFilter.hasOptionKey(options, key: key)
    }

    private static func shellQuote(_ value: String) -> String {
        let safePattern = "^[A-Za-z0-9_@%+=:,./-]+$"
        if value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

extension WorkspaceRemoteConfiguration {
    var sshTerminalStartupEnvironment: [String: String]? {
        guard let agentSocketPath = self.agentSocketPath else {
            return nil
        }
        return ["SSH_AUTH_SOCK": agentSocketPath]
    }

    var sshProcessEnvironment: [String: String]? {
        guard let agentSocketPath = self.agentSocketPath else {
            return nil
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = agentSocketPath
        return environment
    }

    static func forkedAgentSSHOptions(_ options: [String]) -> [String] {
        WorkspaceRemoteSSHOptionFilter.forkedWorkspaceOptions(options)
    }

    func sessionSnapshot(sshOptionsOverride: [String]? = nil) -> SessionRemoteWorkspaceSnapshot? {
        guard transport == .ssh else { return nil }
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty else { return nil }

        return SessionRemoteWorkspaceSnapshot(
            transport: transport,
            destination: normalizedDestination,
            port: port,
            identityFile: WorkspaceRemoteSSHOptionFilter.normalizedIdentityPath(identityFile),
            sshOptions: sshOptionsOverride ?? WorkspaceRemoteSSHOptionFilter.durableOptions(sshOptions),
            preserveAfterTerminalExit: preserveAfterTerminalExit ? true : nil,
            skipDaemonBootstrap: skipDaemonBootstrap,
            relayPort: preserveAfterTerminalExit ? relayPort : nil,
            persistentDaemonSlot: preserveAfterTerminalExit ? persistentDaemonSlot : nil
        )
    }
}
