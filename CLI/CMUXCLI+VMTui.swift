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

        Open a workspace attached to the machine's cmux-tui remote daemon. The pane
        runs the local cmux-tui client against the machine's authenticated link; the
        first attach from this Mac enrolls the device (approved by cmux), later
        attaches reconnect with the stored device key.

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
    }

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
        let opened = try openVMTuiWorkspace(vmId: vmId, windowRaw: windowRaw, client: client)
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
        guard let clientPath, let clientProbe else {
            let searched = cmuxTuiClientCandidates().joined(separator: ", ")
            let template = CMUXDiffViewerLocalization.string(
                "cli.vm.tui.clientMissingSearched",
                defaultValue: "No cmux-tui client found (searched: %1$@). Install one with `curl -fsSL https://cmux.com/tui/install-static.sh | sh`, or point CMUX_TUI_CLIENT at a binary."
            )
            throw CLIError(message: String(format: template, searched))
        }
        logVMTiming("cmux_remote_info", vmID: vmId, transport: "cmux-remote", startedAt: startedAt)
        try Self.checkCmuxTuiCompatibility(client: clientProbe, daemon: info["daemon_build"] as? [String: Any])
        let session = (info["session"] as? String) ?? "cloud"
        let invitation = info["invitation"] as? [String: Any]
        let invitationUri = invitation?["uri"] as? String
        let invitationId = invitation?["invitation_id"] as? String

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
        let initialCommand = "\(shellQuote(executablePath)) vm-tui-connect --config \(shellQuote(configURL.path))"
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
            terminalSurfaceId: terminalSurfaceId,
            session: session,
            enrolling: invitationUri != nil
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
