import Foundation

/// Cloud machines attach through their cmux-tui remote daemon
/// (docs/cloud-cmux-tui-daemon.md). This is the one open path every entrypoint
/// shares — `cmux vm shell|new|fork|restore|base open|base reset`, the Machines
/// panel, and the sidebar cloud button all land in `openVMTuiWorkspace`.
///
/// The control plane returns a tokenized `/v1/link` route and, for a device that has
/// not enrolled with this machine's daemon yet, a single-use invitation. A workspace
/// pane runs the hidden `vm-tui-connect` helper, which hands the terminal to the
/// local cmux-tui client (`remote connect`) and, while the client claims the
/// invitation, asks the control plane to approve the pending enrollment through the
/// app socket. After the first enrollment the device key lives in the client's state
/// directory and later attaches need only a fresh route.
extension CMUXCLI {
    struct VMTuiConnectConfig: Codable {
        let vmId: String
        let route: String
        let session: String
        let invitationUri: String?
        let invitationId: String?
        let clientPath: String
        let stateDir: String
        let deviceName: String
    }

    /// How an entrypoint wants the machine's workspace shaped; the session itself is
    /// the same cmux-tui link in every case.
    struct VMTuiOpenOptions {
        /// Sidebar title; nil means `vm:<id>`.
        var workspaceName: String? = nil
        /// A workspace the app pre-created with a Cloud VM loading pane (`--workspace`):
        /// the link replaces that pane instead of opening a new workspace.
        var targetWorkspaceId: String? = nil
        /// Base — the single persistent cloud workspace — is pinned to the top and
        /// bound as base so the sidebar cloud button reuses it.
        var pinAsBase: Bool = false
        /// `vm tui` only: the pane execs the full cmux-tui client (its own workspaces and
        /// panes). Every other open lands a plain terminal on the machine — the app
        /// creates one in the machine's session and attaches just that terminal, like an
        /// ssh session — so nothing here needs a local client.
        var fullClient: Bool = false
    }

    struct VMTuiDeviceRecord: Codable {
        let deviceFingerprint: String
        let updatedAtUnix: Int
    }

    static let vmTuiApprovalPollSeconds: TimeInterval = 2
    static let vmTuiApprovalTimeoutSeconds: TimeInterval = 5 * 60

    static var vmTuiUsage: String {
        """
        Usage: cmux vm tui <id> [--window <id|ref|index>]

        Open the FULL cmux-tui client for a machine (its own workspaces, panes and
        tabs) in a pane. `cmux vm shell <id>` and every other open give you a plain
        terminal on the machine instead; use this when you want the client itself.
        The pane runs the local cmux-tui client against the machine's authenticated
        link; the first attach from this Mac enrolls the device (approved by cmux),
        later attaches reconnect with the stored device key.

        The client binary is found via CMUX_TUI_CLIENT, then ~/.cmux/bin/cmux, then
        `cmux-tui` on PATH. Install one with:
          curl -fsSL https://cmux.com/tui/install-static.sh | sh
        """
    }

    // MARK: - local state

    /// Per-Mac cmux-tui client state (device key, known daemons), separate from any
    /// interactive `cmux-tui` the person uses so machines never share identity.
    static func vmTuiClientStateDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("cmux-tui-client", isDirectory: true)
    }

    static func vmTuiDevicesStoreURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("vm-tui-devices.json", isDirectory: false)
    }

    static func loadVMTuiDevices(from url: URL? = nil) -> [String: VMTuiDeviceRecord] {
        let storeURL = url ?? vmTuiDevicesStoreURL()
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode([String: VMTuiDeviceRecord].self, from: data) else {
            return [:]
        }
        return store
    }

    static func saveVMTuiDevice(vmId: String, deviceFingerprint: String, to url: URL? = nil) {
        let storeURL = url ?? vmTuiDevicesStoreURL()
        var store = loadVMTuiDevices(from: storeURL)
        store[vmId] = VMTuiDeviceRecord(deviceFingerprint: deviceFingerprint, updatedAtUnix: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }

    /// The client bundled beside this CLI (`Contents/Resources/bin/cmux-tui`, installed by
    /// scripts/install-cmux-tui-client.sh) comes first, so the Machines panel needs no
    /// install; then CMUX_TUI_CLIENT, ~/.cmux/bin/cmux (install-static.sh's target) and
    /// `cmux-tui` on PATH. Plain `cmux` on PATH is deliberately not probed: that is this
    /// CLI. Every candidate must answer `remote-probe --json` as cmux-tui —
    /// ~/.cmux/bin/cmux can also be the SSH-remote bootstrap's shell wrapper, which is
    /// executable but not a client.
    func locateCmuxTuiClient(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        return cmuxTuiClientCandidates(environment: environment)
            .first { fm.isExecutableFile(atPath: $0) && Self.cmuxTuiClientProbe(at: $0) != nil }
    }

    /// Every path `locateCmuxTuiClient` considers, in order — the same list a
    /// missing-client error reports so the fix is obvious.
    func cmuxTuiClientCandidates(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var candidates: [String] = []
        if let bundled = resolvedExecutableURL()?.deletingLastPathComponent().appendingPathComponent("cmux-tui").path {
            candidates.append(bundled)
        }
        if let explicit = environment["CMUX_TUI_CLIENT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            candidates.append(explicit)
        }
        candidates.append(
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".cmux/bin/cmux", isDirectory: false).path
        )
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: String(dir), isDirectory: true).appendingPathComponent("cmux-tui").path)
        }
        return candidates
    }

    struct CmuxTuiClientProbe {
        let buildIdentity: String?
        let remoteProtocol: Int?
        let version: String?
        /// Transport capabilities the client advertises (`direct-ws-user-agent`, …);
        /// forwarded to the control plane, which picks the machine host by them.
        let capabilities: [String]
    }

    /// The `capabilities` array of a probe: lowercase slugs only, in order, deduplicated.
    static func cmuxTuiProbeCapabilities(_ raw: Any?) -> [String] {
        guard let entries = raw as? [Any] else { return [] }
        var seen = Set<String>()
        return entries.compactMap { entry -> String? in
            guard let token = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  token.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil,
                  seen.insert(token).inserted else { return nil }
            return token
        }
    }

    /// `remote-probe --json` of a candidate binary; nil unless it is a cmux-tui client.
    static func cmuxTuiClientProbe(at path: String) -> CmuxTuiClientProbe? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["remote-probe", "--json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["app"] as? String) == "cmux-tui" else {
            return nil
        }
        return CmuxTuiClientProbe(
            buildIdentity: object["build_identity"] as? String,
            remoteProtocol: (object["remote_protocol"] as? Int) ?? (object["remote_protocol"] as? Double).map(Int.init),
            version: object["version"] as? String,
            capabilities: cmuxTuiProbeCapabilities(object["capabilities"])
        )
    }

    /// Client and machine daemon must speak the same remote protocol; the daemon rejects a
    /// mismatch, so say which side is behind up front instead of letting the pane hang.
    static func checkCmuxTuiCompatibility(client: CmuxTuiClientProbe, daemon: [String: Any]?) throws {
        guard let daemon,
              let daemonProtocol = (daemon["remote_protocol"] as? Int) ?? (daemon["remote_protocol"] as? Double).map(Int.init),
              let clientProtocol = client.remoteProtocol,
              daemonProtocol != clientProtocol else { return }
        let daemonCommit = (daemon["commit"] as? String).map { String($0.prefix(10)) } ?? "?"
        let clientCommit = client.buildIdentity.map { String($0.prefix(10)) } ?? "?"
        let stale = clientProtocol < daemonProtocol
            ? CMUXDiffViewerLocalization.string("cli.vm.tui.staleClient", defaultValue: "Update cmux (its bundled cmux-tui client is older than the machine's daemon).")
            : CMUXDiffViewerLocalization.string("cli.vm.tui.staleDaemon", defaultValue: "The machine's cmux-tui daemon is older than this client; reconnect once the machine has updated.")
        let template = CMUXDiffViewerLocalization.string(
            "cli.vm.tui.protocolMismatch",
            defaultValue: "cmux-tui protocol mismatch: client %1$@ speaks protocol %2$d, the machine daemon %3$@ speaks protocol %4$d. %5$@"
        )
        throw CLIError(message: String(format: template, clientCommit, clientProtocol, daemonCommit, daemonProtocol, stale))
    }

    static func vmTuiDeviceName() -> String {
        let raw = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : Character("-") }
        return "cmux-" + String(cleaned).prefix(40)
    }

    // MARK: - cmux vm tui <id>  (and the default for cmux vm shell)

    struct VMTuiOpenResult {
        let workspaceId: String
        let workspaceRef: String?
        let windowId: String?
        /// The pane running the cmux-tui client; keyboard focus belongs here even after
        /// a desktop split opens beside it.
        let terminalSurfaceId: String?
        let session: String
        let enrolling: Bool
        /// The machine-side terminal the pane shows (`term_…`) and its cmux-tui
        /// workspace (`ws_…`); nil for `vm tui`, whose pane is the whole client.
        let terminalId: String?
        let remoteWorkspaceId: String?
    }

    /// What the placeholder pane runs while the app opens the machine's terminal beside
    /// it: `vm.terminal_new` splits the workspace's focused pane, so the placeholder has to
    /// stay alive until that split lands; it is closed right after.
    static let vmPlainTerminalPlaceholderCommand = "sleep 60"

    /// The shared cloud open path (`vmOpenShell`) calls this first for every entrypoint.
    /// Returns nil only when the control plane says the machine's deployment does not
    /// run cmux-tui at all (providers that predate the migration), so the caller may
    /// fall back to their transport. Any other failure — including a machine that
    /// reports it attaches through cmux-tui only — surfaces as-is; nothing falls back
    /// to a websocket attach the backend will refuse.
    func openVMShellViaCmuxTuiIfAvailable(
        vmId: String,
        windowRaw: String?,
        options: VMTuiOpenOptions = VMTuiOpenOptions(),
        client: SocketClient
    ) throws -> VMTuiOpenResult? {
        do {
            return try openVMTuiWorkspace(vmId: vmId, windowRaw: windowRaw, options: options, client: client)
        } catch let error as CLIError where Self.isCmuxTuiUnavailable(error) {
            return nil
        }
    }

    /// Backend code the control plane returns when a machine refuses the legacy attach
    /// because it runs cmux-tui only; it means "use cmux-tui", never "fall back".
    static let vmAttachTransportUnsupportedCode = "vm_attach_transport_unsupported"

    static func isCmuxTuiUnavailable(_ error: CLIError) -> Bool {
        if error.vmBackendCode == vmAttachTransportUnsupportedCode {
            return false
        }
        let text = error.message.lowercased()
        if text.contains(vmAttachTransportUnsupportedCode) || text.contains("cmux-tui only") {
            return false
        }
        return text.contains("not enabled for this deployment")
            || text.contains("not supported by this deployment")
            || text.contains("does not run the cmux-tui")
            || text.contains("unknown method")
    }

    func runVMTuiCommand(rest: [String], windowRaw: String?, client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmTuiUsage)
            return
        }
        guard let vmId = rest.first(where: { !$0.hasPrefix("-") }), !vmId.isEmpty else {
            throw CLIError(message: Self.vmTuiUsage)
        }
        let opened = try openVMTuiWorkspace(
            vmId: vmId,
            windowRaw: windowRaw,
            options: VMTuiOpenOptions(fullClient: true),
            client: client
        )
        if jsonOutput {
            print(jsonString([
                "ok": true,
                "vm_id": vmId,
                "workspace_id": opened.workspaceId,
                "session": opened.session,
                "enrolling": opened.enrolling,
            ]))
            return
        }
        let template = CMUXDiffViewerLocalization.string(
            "cli.vm.tui.opened",
            defaultValue: "Opened cmux-tui for %1$@ (%2$@)"
        )
        let mode = opened.enrolling
            ? CMUXDiffViewerLocalization.string("cli.vm.tui.mode.enrolling", defaultValue: "enrolling this Mac")
            : CMUXDiffViewerLocalization.string("cli.vm.tui.mode.enrolled", defaultValue: "device already enrolled")
        print(String(format: template, vmId, mode))
    }

    func openVMTuiWorkspace(
        vmId: String,
        windowRaw: String?,
        options: VMTuiOpenOptions = VMTuiOpenOptions(),
        client: SocketClient
    ) throws -> VMTuiOpenResult {
        let startedAt = Date()
        let known = Self.loadVMTuiDevices()[vmId]
        // Probe the local client before asking the control plane: what it can do
        // (`capabilities`) decides which machine host the route points at. A missing
        // client is still only reported once the machine is confirmed reachable
        // through cmux-tui, so deployments without the daemon fall back cleanly.
        let clientPath = locateCmuxTuiClient()
        let clientProbe = clientPath.flatMap { Self.cmuxTuiClientProbe(at: $0) }
        var infoParams: [String: Any] = ["id": vmId]
        if let known {
            infoParams["device_fingerprint"] = known.deviceFingerprint
        }
        if let capabilities = clientProbe?.capabilities, !capabilities.isEmpty {
            infoParams["client_capabilities"] = capabilities
        }
        let info = try client.sendV2(method: "vm.cmux_remote_info", params: infoParams, responseTimeout: 16 * 60)
        guard let route = info["route"] as? String, !route.isEmpty else {
            throw CLIError(message: "vm.cmux_remote_info returned no route")
        }
        // The plain-terminal path runs the app's bundled client, so a missing local
        // client only matters for `vm tui` (the pane execs it).
        if options.fullClient, clientPath == nil || clientProbe == nil {
            let searched = cmuxTuiClientCandidates().joined(separator: ", ")
            let template = CMUXDiffViewerLocalization.string(
                "cli.vm.tui.clientMissingSearched",
                defaultValue: "No cmux-tui client found (searched: %1$@). Install one with `curl -fsSL https://cmux.com/tui/install-static.sh | sh`, or point CMUX_TUI_CLIENT at a binary."
            )
            throw CLIError(message: String(format: template, searched))
        }
        logVMTiming("cmux_remote_info", vmID: vmId, transport: "cmux-remote", startedAt: startedAt)
        if let clientProbe {
            try Self.checkCmuxTuiCompatibility(client: clientProbe, daemon: info["daemon_build"] as? [String: Any])
        }
        let session = (info["session"] as? String) ?? "cloud"
        let invitation = info["invitation"] as? [String: Any]
        let invitationUri = invitation?["uri"] as? String
        let invitationId = invitation?["invitation_id"] as? String

        let initialCommand: String
        if options.fullClient, let clientPath {
            let stateDir = Self.vmTuiClientStateDir()
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let config = VMTuiConnectConfig(
                vmId: vmId,
                route: route,
                session: session,
                invitationUri: invitationUri,
                invitationId: invitationId,
                clientPath: clientPath,
                stateDir: stateDir.path,
                deviceName: Self.vmTuiDeviceName()
            )
            let configURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-vm-tui-\(UUID().uuidString.lowercased()).json")
            try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
            initialCommand = "\(shellQuote(executablePath)) vm-tui-connect --config \(shellQuote(configURL.path))"
        } else {
            initialCommand = Self.vmPlainTerminalPlaceholderCommand
        }
        let workspaceId: String
        let workspaceRef: String?
        let windowId: String?
        let terminalSurfaceId: String?
        let didCreateWorkspace: Bool
        if let target = options.targetWorkspaceId?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
            // The app pre-created this workspace with a loading pane; the link takes
            // that pane's place (no new workspace, no title change).
            let ready = try client.sendV2(
                method: "workspace.cloud_vm_terminal_ready",
                params: ["workspace_id": target, "initial_command": initialCommand, "focus": true]
            )
            workspaceId = (ready["workspace_id"] as? String) ?? target
            workspaceRef = ready["workspace_ref"] as? String
            windowId = (ready["window_id"] as? String) ?? windowRaw
            terminalSurfaceId = ready["surface_id"] as? String
            didCreateWorkspace = false
        } else {
            let requestedTitle = options.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var params: [String: Any] = [
                "initial_command": initialCommand,
                "title": requestedTitle.isEmpty ? "vm:\(vmId)" : requestedTitle,
            ]
            try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowRaw)
            let created = try client.sendV2(method: "workspace.create", params: params)
            guard let createdId = created["workspace_id"] as? String, !createdId.isEmpty else {
                throw CLIError(message: "workspace.create did not return workspace_id")
            }
            workspaceId = createdId
            workspaceRef = created["workspace_ref"] as? String
            windowId = created["window_id"] as? String
            terminalSurfaceId = created["surface_id"] as? String
            didCreateWorkspace = true
        }
        do {
            // The binding is how the app finds this machine's workspace again (Machines
            // panel Open, `cmux vm desktop`, the sidebar cloud button's Base reuse).
            _ = try client.sendV2(
                method: "workspace.cloud_vm_bind",
                params: ["workspace_id": workspaceId, "vm_id": vmId, "base": options.pinAsBase]
            )
            if options.pinAsBase {
                try pinWorkspaceToTop(workspaceId: workspaceId, windowId: windowId, client: client)
            }
        } catch {
            if didCreateWorkspace {
                _ = try? client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            }
            throw error
        }
        var paneSurfaceId = terminalSurfaceId
        var terminalId: String?
        var remoteWorkspaceId: String?
        if !options.fullClient {
            // The pane is a plain terminal on the machine: the app creates one in the
            // machine's cmux-tui session over its headless link and attaches just that
            // terminal (`attach --terminal`) beside the placeholder, which is then closed.
            // Same path the Cloud tree uses, so the terminal shows up there as open.
            let terminalStartedAt = Date()
            do {
                let opened = try client.sendV2(
                    method: "vm.terminal_new",
                    params: ["id": vmId, "open": true, "local_workspace_id": workspaceId, "focus": true, "name": "shell"],
                    responseTimeout: 180
                )
                terminalId = opened["terminal_id"] as? String
                remoteWorkspaceId = opened["workspace_id"] as? String
                let newSurface = (opened["surface_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let placeholder = terminalSurfaceId, !placeholder.isEmpty, placeholder != newSurface {
                    _ = try? client.sendV2(method: "surface.close", params: ["workspace_id": workspaceId, "surface_id": placeholder])
                }
                paneSurfaceId = newSurface ?? terminalSurfaceId
            } catch {
                if didCreateWorkspace {
                    _ = try? client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
                }
                throw error
            }
            logVMTiming("terminal_new", vmID: vmId, transport: "cmux-remote", startedAt: terminalStartedAt)
        }
        var selectParams: [String: Any] = ["workspace_id": workspaceId]
        if let windowId, !windowId.isEmpty {
            selectParams["window_id"] = windowId
        }
        _ = try? client.sendV2(method: "workspace.select", params: selectParams)
        logVMTiming(
            "complete",
            vmID: vmId,
            transport: "cmux-remote",
            startedAt: startedAt,
            extra: "workspace=\(String(workspaceId.prefix(8)))"
        )
        return VMTuiOpenResult(
            workspaceId: workspaceId,
            workspaceRef: workspaceRef,
            windowId: windowId,
            terminalSurfaceId: paneSurfaceId,
            session: session,
            enrolling: invitationUri != nil,
            terminalId: terminalId,
            remoteWorkspaceId: remoteWorkspaceId
        )
    }

    // MARK: - cmux vm-tui-connect --config <file>  (runs inside the pane)

    /// The argv the pane hands to the cmux-tui client. Pure, so the exec line can be
    /// checked without a pane.
    static func vmTuiConnectArguments(config: VMTuiConnectConfig, inviteFilePath: String?) -> [String] {
        var arguments = ["remote", "connect", config.route, "--device-name", config.deviceName, "--state-dir", config.stateDir]
        if let inviteFilePath, !inviteFilePath.isEmpty {
            arguments += ["--invite-file", inviteFilePath]
        }
        return arguments
    }

    /// Replaces this process with the cmux-tui client. The pane's foreground process is
    /// the client from its very first tty read: spawning it as a child and moving it to
    /// the foreground afterwards raced its `tcsetattr` (raw mode) against the handoff,
    /// which intermittently left the tty cooked — keystrokes line-buffered or swallowed.
    /// Enrollment approval, which used to poll from a thread here, runs in a detached
    /// helper (`vm-tui-approve`) so nothing in this process has to outlive the exec.
    func runVMTuiConnect(commandArgs: [String], client: SocketClient) throws {
        let (configPath, _) = parseOption(commandArgs, name: "--config")
        guard let configPath, !configPath.isEmpty else {
            throw CLIError(message: "Usage: cmux vm-tui-connect --config <file>")
        }
        let configURL = URL(fileURLWithPath: configPath)
        let config = try JSONDecoder().decode(VMTuiConnectConfig.self, from: Data(contentsOf: configURL))
        // The config carries a single-use invitation secret; it has served its purpose.
        try? FileManager.default.removeItem(at: configURL)

        var inviteURL: URL?
        if let uri = config.invitationUri, !uri.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-vm-tui-invite-\(UUID().uuidString.lowercased())")
            try (uri + "\n").data(using: .utf8)!.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            inviteURL = url
        }

        cliWriteStderr(String(format: CMUXDiffViewerLocalization.string(
            "cli.vm.tui.connecting",
            defaultValue: "Connecting to %1$@ through cmux-tui…"
        ), config.vmId) + "\n")

        // While the client claims the invitation, approve the pending enrollment through
        // the app: the control plane minted this invitation for the signed-in user, so
        // approving the claim is the honest encoding of "already authenticated". The
        // helper owns the invite file's lifetime and removes it once the claim is
        // approved or the window closes.
        if let invitationId = config.invitationId, !invitationId.isEmpty {
            var approverArguments = ["vm-tui-approve", "--id", config.vmId, "--invitation-id", invitationId]
            if let inviteURL {
                approverArguments += ["--invite-file", inviteURL.path]
            }
            let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
            do {
                try Self.spawnDetachedVMTuiApprover(
                    executablePath: executablePath,
                    arguments: approverArguments,
                    socketPath: client.socketPath
                )
            } catch {
                if let inviteURL { try? FileManager.default.removeItem(at: inviteURL) }
                throw error
            }
        }

        let arguments = Self.vmTuiConnectArguments(config: config, inviteFilePath: inviteURL?.path)
        try execInteractiveProgram(launchPath: config.clientPath, arguments: arguments)
    }

    /// Spawns `cmux vm-tui-approve …` in its own session with stdio on /dev/null, so it
    /// survives the pane's exec and never touches the tty the client is about to own.
    static func spawnDetachedVMTuiApprover(executablePath: String, arguments: [String], socketPath: String) throws {
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw CLIError(message: "vm-tui-connect: couldn't prepare the enrollment approver (file actions)")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let status = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(&fileActions, fd, path, fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
            }
            guard status == 0 else {
                throw CLIError(message: "vm-tui-connect: couldn't detach the enrollment approver from the terminal")
            }
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CLIError(message: "vm-tui-connect: couldn't prepare the enrollment approver (attributes)")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            throw CLIError(message: "vm-tui-connect: couldn't give the enrollment approver its own session")
        }

        // Same socket the pane talks to; CMUX_SOCKET (the ambient terminal's socket) must
        // not win over it, as the CLI's other child spawns also ensure.
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment.removeValue(forKey: "CMUX_SOCKET")
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        var argv = ([executablePath] + arguments).map { strdup($0) }
        var envp = environmentStrings.map { strdup($0) }
        defer {
            for item in argv { free(item) }
            for item in envp { free(item) }
        }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executablePath, &fileActions, &attributes, &argv, &envp)
        guard status == 0 else {
            throw CLIError(message: "vm-tui-connect: couldn't start the enrollment approver: \(String(cString: strerror(status)))")
        }
    }

    // MARK: - cmux vm-tui-approve --id <vm> --invitation-id <id> [--invite-file <path>]  (detached)

    /// Approves a pending cmux-tui enrollment through the app while the pane's client
    /// claims the invitation. Silent: it owns no terminal. Ends when the claim is
    /// approved or `vmTuiApprovalTimeoutSeconds` pass, and deletes the invite file
    /// either way.
    func runVMTuiApprove(commandArgs: [String], client: SocketClient) throws {
        let (vmIdOpt, rest0) = parseOption(commandArgs, name: "--id")
        let (invitationOpt, rest1) = parseOption(rest0, name: "--invitation-id")
        let (inviteFileOpt, _) = parseOption(rest1, name: "--invite-file")
        guard let vmId = vmIdOpt, !vmId.isEmpty, let invitationId = invitationOpt, !invitationId.isEmpty else {
            throw CLIError(message: "Usage: cmux vm-tui-approve --id <vm> --invitation-id <id> [--invite-file <path>]")
        }
        defer {
            if let inviteFileOpt, !inviteFileOpt.isEmpty {
                try? FileManager.default.removeItem(atPath: inviteFileOpt)
            }
        }
        let deadline = Date().addingTimeInterval(Self.vmTuiApprovalTimeoutSeconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: Self.vmTuiApprovalPollSeconds)
            guard let result = try? client.sendV2(
                method: "vm.cmux_remote_approve",
                params: ["id": vmId, "invitation_id": invitationId],
                responseTimeout: 60
            ) else { continue }
            if (result["state"] as? String) == "approved" {
                if let fingerprint = result["device_fingerprint"] as? String, !fingerprint.isEmpty {
                    Self.saveVMTuiDevice(vmId: vmId, deviceFingerprint: fingerprint)
                }
                return
            }
        }
    }
}

// MARK: - vm tree / vm open <target> (the cloud tree)

extension CMUXCLI {
    /// Where `cmux vm open <target>` points. Grammar:
    ///   <machine>                      the machine's shell (the shared vmOpenShell path)
    ///   <machine>/<workspace>          a cmux-tui workspace on the machine (`ws_…` id or name)
    ///   <machine>/<workspace>/<term>   one terminal in it (`term_…`)
    ///   <machine>:desktop              the machine's noVNC screen
    ///   <machine>:port/<n>             a forwarded HTTP port
    /// The same addresses appear in `cmux vm tree`, so an agent can copy them verbatim.
    enum VMOpenTarget: Equatable {
        case machine(String)
        case workspace(machine: String, workspace: String)
        case terminal(machine: String, workspace: String, terminal: String)
        case desktop(String)
        case port(machine: String, port: Int)

        var machine: String {
            switch self {
            case .machine(let id), .desktop(let id):
                return id
            case .workspace(let id, _), .terminal(let id, _, _), .port(let id, _):
                return id
            }
        }
    }

    static func parseVMOpenTarget(_ raw: String) -> VMOpenTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        if let colon = trimmed.firstIndex(of: ":") {
            let machine = String(trimmed[..<colon])
            let selector = String(trimmed[trimmed.index(after: colon)...])
            guard !machine.isEmpty, !machine.contains("/") else { return nil }
            if selector == "desktop" || selector == "vnc" || selector == "screen" {
                return .desktop(machine)
            }
            if selector.hasPrefix("port/"),
               let port = Int(selector.dropFirst("port/".count)),
               (1...65535).contains(port) {
                return .port(machine: machine, port: port)
            }
            return nil
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        switch parts.count {
        case 1:
            return .machine(parts[0])
        case 2:
            return .workspace(machine: parts[0], workspace: parts[1])
        case 3:
            return .terminal(machine: parts[0], workspace: parts[1], terminal: parts[2])
        default:
            return nil
        }
    }

    static var vmTreeUsage: String {
        """
        Usage: cmux vm tree [<machine>] [--refresh] [--json]

        The Finder-style view of your cloud machines: each machine, the cmux-tui
        workspaces running on it, the terminals in each workspace (with title, cwd,
        agent state, and whether a pane in this app already shows it), then the
        machine's desktop and forwarded ports. Every line carries the address
        `cmux vm open` accepts.

        Options:
          <machine>   Only this machine.
          --refresh   Re-read the machine's session instead of the cached tree.
          --json      Print the raw payload ({machines: [...]}).
        """
    }

    static var vmOpenUsage: String {
        """
        Usage: cmux vm open <target> [--workspace <id|ref|index>] [--focus <true|false>] [--print]
               cmux vm open <id> <port> [--print]

        Targets (copy them from `cmux vm tree`):
          <machine>                      the machine's shell (same as `cmux vm shell <machine>`)
          <machine>/<workspace>          a cmux-tui workspace on it (`ws_…` id or name)
          <machine>/<workspace>/<term>   one terminal (`term_…`) — focuses the pane that
                                         already shows it instead of opening a second one
          <machine>:desktop              the machine's noVNC screen as a browser pane
          <machine>:port/<n>             a private tokened URL for an HTTP port, as a browser pane
          <machine> <port>               same as <machine>:port/<port>

        Options:
          --workspace <ws>   Put the pane in this local workspace (default: the machine's
                             open workspace, else where you are).
          --focus <bool>     Focus the opened pane (default: false — panes open beside you).
          --print            Ports only: print the URL, do not open a pane.

        Examples:
          cmux vm open vivid-newt
          cmux vm open vivid-newt/main
          cmux vm open vivid-newt/main/term_2f9c…
          cmux vm open vivid-newt:desktop
          cmux vm open vivid-newt:port/3000 --print
        """
    }

    func runVMTreeCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.vmTreeUsage)
            return
        }
        let refresh = hasFlag(rest, name: "--refresh")
        if let unknown = rest.first(where: { $0.hasPrefix("-") && !["--refresh", "--json"].contains($0) }) {
            throw CLIError(message: "vm tree: unknown flag '\(unknown)'\n\n\(Self.vmTreeUsage)")
        }
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard positional.count <= 1 else {
            throw CLIError(message: Self.vmTreeUsage)
        }
        var params: [String: Any] = [:]
        if let machine = positional.first { params["id"] = machine }
        if refresh { params["refresh"] = true }
        let response = try client.sendV2(method: "vm.tree", params: params, responseTimeout: 120)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let machines = (response["machines"] as? [[String: Any]]) ?? []
        guard !machines.isEmpty else {
            print(String(localized: "cli.vm.tree.empty", defaultValue: "No cloud machines. Try: cmux vm new"))
            return
        }
        for (index, machine) in machines.enumerated() {
            if index > 0 { print("") }
            for line in Self.vmTreeLines(machine: machine) {
                print(line)
            }
        }
    }

    private static func vmTreeNumber(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? Int64 { return Double(v) }
        return nil
    }

    /// The human rendering of one `vm.tree` machine entry. Pure, so the shape is testable
    /// and the same lines can back other surfaces.
    static func vmTreeLines(machine: [String: Any]) -> [String] {
        var lines: [String] = []
        let id = (machine["id"] as? String) ?? "?"
        let status = (machine["status"] as? String) ?? "unknown"
        var facts: [String] = []
        if let memoryMb = vmTreeNumber(machine["memory_mb"]), memoryMb > 0 {
            facts.append(String(format: "%.0f GB", memoryMb / 1024))
        }
        if let diskMb = vmTreeNumber(machine["disk_mb"]), diskMb > 0 {
            facts.append(String(format: String(localized: "cli.vm.tree.disk", defaultValue: "%.0f GB disk"), diskMb / 1024))
        }
        let link = machine["link"] as? [String: Any]
        let linkState = (link?["state"] as? String) ?? ""
        let linkError = (link?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if !linkState.isEmpty {
            facts.append(String(format: String(localized: "cli.vm.tree.link", defaultValue: "link %@"), linkState))
        }
        lines.append(facts.isEmpty ? "\(id)  \(status)" : "\(id)  \(status)  · " + facts.joined(separator: " · "))

        lines.append("  " + String(localized: "cli.vm.tree.workspaces", defaultValue: "workspaces/"))
        let workspaces = (machine["workspaces"] as? [[String: Any]]) ?? []
        // The link state decides what an empty workspace list means: a machine that is
        // asleep, still connecting, or whose link failed has workspaces the tree simply
        // cannot see yet, and hiding that behind "none yet" hides the failure.
        switch linkState {
        case "connecting":
            lines.append("    " + String(localized: "cli.vm.tree.link.connecting", defaultValue: "connecting…"))
        case "asleep":
            lines.append("    " + String(
                format: String(localized: "cli.vm.tree.link.asleep", defaultValue: "asleep — cmux vm open %@ wakes it"),
                id
            ))
        case "error", "unavailable":
            lines.append("    " + String(
                format: String(localized: "cli.vm.tree.link.error", defaultValue: "⚠ link %@: %@"),
                linkState,
                linkError ?? linkState
            ))
            lines.append("    " + String(
                format: String(localized: "cli.vm.tree.link.retry", defaultValue: "retry: cmux vm tree %@ --refresh"),
                id
            ))
        default:
            if workspaces.isEmpty {
                lines.append("    " + String(
                    format: String(localized: "cli.vm.tree.noWorkspaces", defaultValue: "(none yet — cmux vm open %@ starts one)"),
                    id
                ))
            }
        }
        for workspace in workspaces {
            let workspaceId = (workspace["id"] as? String) ?? "?"
            let name = (workspace["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? workspaceId
            let focused = (workspace["focused"] as? Bool) == true
            lines.append("    \(name)  \(workspaceId)\(focused ? "  *" : "")  (cmux vm open \(id)/\(workspaceId))")
            let terminals = (workspace["terminals"] as? [[String: Any]]) ?? []
            if terminals.isEmpty {
                lines.append("      " + String(localized: "cli.vm.tree.noTerminals", defaultValue: "(no terminals)"))
            }
            for terminal in terminals {
                let terminalId = (terminal["id"] as? String) ?? "?"
                let lifecycle = (terminal["lifecycle"] as? String) ?? "running"
                let glyph: String
                switch lifecycle {
                case "launching": glyph = "…"
                case "exited": glyph = "○"
                default: glyph = "●"
                }
                var cell = "      \(glyph) \(terminalId)"
                if let title = terminal["title"] as? String, !title.isEmpty { cell += "  \(title)" }
                if let cwd = terminal["cwd"] as? String, !cwd.isEmpty { cell += "  \(cwd)" }
                if let agent = terminal["agent"] as? [String: Any], let state = agent["state"] as? String, !state.isEmpty {
                    let source = (agent["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let label = source.map { "\($0) \(state)" } ?? state
                    cell += "  " + String(format: String(localized: "cli.vm.tree.agent", defaultValue: "[agent %@]"), label)
                }
                if let open = terminal["open_surface_id"] as? String, !open.isEmpty {
                    cell += "  " + String(format: String(localized: "cli.vm.tree.open", defaultValue: "(open: %@)"), open)
                }
                lines.append(cell)
            }
        }
        if (machine["desktop"] as? Bool) == true {
            lines.append("  " + String(
                format: String(localized: "cli.vm.tree.desktop", defaultValue: "desktop  (cmux vm open %@:desktop)"),
                id
            ))
        }
        let ports = (machine["ports"] as? [[String: Any]]) ?? []
        if !ports.isEmpty {
            lines.append("  " + String(localized: "cli.vm.tree.ports", defaultValue: "ports/"))
            for entry in ports {
                guard let port = vmTreeNumber(entry["port"]).map({ Int($0) }) else { continue }
                let label = (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                lines.append("    \(port)\(label.map { "  \($0)" } ?? "")  (cmux vm open \(id):port/\(port))")
            }
        }
        return lines
    }

    /// `vm open <target>` for every form except the bare machine, which cmux.swift routes to
    /// vmOpenShell itself (that path is file-private there). One resolver, so the sidebar
    /// tree, the CLI, and agents open a terminal/desktop/port through the same socket methods.
    func runVMOpenTarget(
        _ target: VMOpenTarget,
        workspaceRaw: String?,
        focus: Bool?,
        printOnly: Bool,
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        switch target {
        case .machine:
            throw CLIError(message: Self.vmOpenUsage)
        case .desktop(let machine):
            let opened = try openVMDesktopSplit(
                vmId: machine,
                client: client,
                workspaceId: workspaceRaw ?? vmAttachedWorkspaceId(vmId: machine, client: client),
                focus: focus ?? false,
                jsonOutput: jsonOutput
            )
            guard opened else {
                throw CLIError(message: String(
                    format: String(localized: "cli.vm.desktop.unavailable", defaultValue: "%@ has no desktop to show. New machines boot a screen; this one was created shell-only (`--base`)."),
                    machine
                ))
            }
        case .port(let machine, let port):
            try openVMPort(vmId: machine, port: port, printOnly: printOnly, workspaceRaw: workspaceRaw, client: client, jsonOutput: jsonOutput)
        case .terminal(let machine, _, let terminal):
            try openVMTerminal(machine: machine, terminalId: terminal, workspaceRaw: workspaceRaw, focus: focus, client: client, jsonOutput: jsonOutput)
        case .workspace(let machine, let workspace):
            let tree = try client.sendV2(method: "vm.tree", params: ["id": machine], responseTimeout: 120)
            let machines = (tree["machines"] as? [[String: Any]]) ?? []
            let workspaces = machines.first(where: { ($0["id"] as? String) == machine })
                .flatMap { $0["workspaces"] as? [[String: Any]] } ?? []
            guard let entry = workspaces.first(where: { ($0["id"] as? String) == workspace })
                ?? workspaces.first(where: { ($0["name"] as? String) == workspace }) else {
                throw CLIError(message: String(
                    format: String(localized: "cli.vm.open.workspaceNotFound", defaultValue: "%1$@ has no workspace '%2$@'. See: cmux vm tree %1$@"),
                    machine, workspace
                ))
            }
            let remoteWorkspaceId = (entry["id"] as? String) ?? workspace
            let terminals = (entry["terminals"] as? [[String: Any]]) ?? []
            let live = terminals.filter { ($0["lifecycle"] as? String) != "exited" }
            if let pick = live.first(where: { ($0["focused"] as? Bool) == true }) ?? live.first,
               let terminalId = pick["id"] as? String {
                try openVMTerminal(machine: machine, terminalId: terminalId, workspaceRaw: workspaceRaw, focus: focus, client: client, jsonOutput: jsonOutput)
                return
            }
            // An empty remote workspace: start a shell in it and show that.
            var params: [String: Any] = ["id": machine, "workspace_id": remoteWorkspaceId, "open": true]
            if let workspaceRaw { params["local_workspace_id"] = workspaceRaw }
            if let focus { params["focus"] = focus }
            let response = try client.sendV2(method: "vm.terminal_new", params: params, responseTimeout: 180)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let terminalId = (response["terminal_id"] as? String) ?? "?"
            let surfaceId = (response["surface_id"] as? String) ?? ""
            print("OK terminal=\(terminalId) workspace=\(remoteWorkspaceId)\(surfaceId.isEmpty ? "" : " surface=\(surfaceId)")")
        }
    }

    func openVMTerminal(
        machine: String,
        terminalId: String,
        workspaceRaw: String?,
        focus: Bool?,
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        var params: [String: Any] = ["id": machine, "terminal_id": terminalId]
        if let workspaceRaw { params["workspace_id"] = workspaceRaw }
        if let focus { params["focus"] = focus }
        let response = try client.sendV2(method: "vm.terminal_open", params: params, responseTimeout: 180)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let surfaceId = (response["surface_id"] as? String) ?? "?"
        let workspaceId = (response["workspace_id"] as? String) ?? "?"
        let reused = (response["reused"] as? Bool) == true
        print("OK surface=\(surfaceId) workspace=\(workspaceId) terminal=\(terminalId)\(reused ? " reused=true" : "")")
    }

    /// The one port path: `vm open <id> <port>`, `vm open <id>:port/<n>`, and the tree all
    /// land here. `--print` only mints the URL (vm.open_port); otherwise the app opens the
    /// browser pane and reports the surface (vm.port_open).
    func openVMPort(
        vmId: String,
        port: Int,
        printOnly: Bool,
        workspaceRaw: String?,
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        if printOnly {
            let payload = try client.sendV2(method: "vm.open_port", params: ["id": vmId, "port": port], responseTimeout: 90)
            if jsonOutput {
                print(jsonString(payload))
                return
            }
            print("\(vmId):\(port)")
            print("  \((payload["open_url"] as? String) ?? "")")
            return
        }
        var params: [String: Any] = ["id": vmId, "port": port]
        if let workspaceRaw { params["workspace_id"] = workspaceRaw }
        let payload = try client.sendV2(method: "vm.port_open", params: params, responseTimeout: 120)
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        print("\(vmId):\(port)")
        print("  \((payload["url"] as? String) ?? (payload["open_url"] as? String) ?? "")")
        if let surfaceId = payload["surface_id"] as? String, !surfaceId.isEmpty {
            print("OK surface=\(surfaceId)")
        }
    }
}
