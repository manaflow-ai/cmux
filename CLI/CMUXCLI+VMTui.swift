import Foundation

/// `cmux vm tui <id>` — attach to a cloud machine through its cmux-tui remote daemon
/// (Phase 1 of the cmuxd-remote → cmux-tui migration, docs/cloud-cmux-tui-daemon.md).
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

    /// CMUX_TUI_CLIENT → ~/.cmux/bin/cmux (install-static.sh's target) → `cmux-tui` on PATH.
    /// Plain `cmux` on PATH is deliberately not probed: that is this CLI. Every candidate
    /// must answer `remote-probe --json` as cmux-tui — ~/.cmux/bin/cmux can also be the
    /// SSH-remote bootstrap's shell wrapper, which is executable but not a client.
    static func locateCmuxTuiClient(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
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
        return candidates.first { fm.isExecutableFile(atPath: $0) && isCmuxTuiClient(at: $0) }
    }

    static func isCmuxTuiClient(at path: String) -> Bool {
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
            return false
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (object["app"] as? String) == "cmux-tui"
    }

    static func vmTuiDeviceName() -> String {
        let raw = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"
        let cleaned = raw.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : Character("-") }
        return "cmux-" + String(cleaned).prefix(40)
    }

    // MARK: - cmux vm tui <id>  (and the default for cmux vm shell)

    struct VMTuiOpenResult {
        let workspaceId: String
        let session: String
        let enrolling: Bool
    }

    /// `cmux vm shell` prefers this path: when the deployment runs the cmux-tui daemon,
    /// every shell is a cmux-tui session. Returns nil only when the control plane says
    /// the machine's deployment has no cmux-tui pin, so the caller can fall back to the
    /// legacy cmuxd-remote websocket attach for machines that predate the migration.
    func openVMShellViaCmuxTuiIfAvailable(vmId: String, windowRaw: String?, client: SocketClient) throws -> VMTuiOpenResult? {
        do {
            return try openVMTuiWorkspace(vmId: vmId, windowRaw: windowRaw, client: client)
        } catch let error as CLIError where Self.isCmuxTuiUnavailable(error) {
            return nil
        }
    }

    static func isCmuxTuiUnavailable(_ error: CLIError) -> Bool {
        let text = error.message.lowercased()
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

    func openVMTuiWorkspace(vmId: String, windowRaw: String?, client: SocketClient) throws -> VMTuiOpenResult {
        let known = Self.loadVMTuiDevices()[vmId]
        var infoParams: [String: Any] = ["id": vmId]
        if let known {
            infoParams["device_fingerprint"] = known.deviceFingerprint
        }
        // Ask the control plane first: a missing client binary should only be reported
        // when this machine can actually be reached through cmux-tui.
        let info = try client.sendV2(method: "vm.cmux_remote_info", params: infoParams, responseTimeout: 16 * 60)
        guard let route = info["route"] as? String, !route.isEmpty else {
            throw CLIError(message: "vm.cmux_remote_info returned no route")
        }
        guard let clientPath = Self.locateCmuxTuiClient() else {
            throw CLIError(message: CMUXDiffViewerLocalization.string(
                "cli.vm.tui.clientMissing",
                defaultValue: "No cmux-tui client found. Install one with `curl -fsSL https://cmux.com/tui/install-static.sh | sh`, or point CMUX_TUI_CLIENT at a binary."
            ))
        }
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
        var params: [String: Any] = [
            "initial_command": "\(shellQuote(executablePath)) vm-tui-connect --config \(shellQuote(configURL.path))",
            "title": "vm:\(vmId)",
        ]
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowRaw)
        let created = try client.sendV2(method: "workspace.create", params: params)
        guard let workspaceId = created["workspace_id"] as? String, !workspaceId.isEmpty else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        _ = try? client.sendV2(method: "workspace.select", params: ["workspace_id": workspaceId])
        return VMTuiOpenResult(workspaceId: workspaceId, session: session, enrolling: invitationUri != nil)
    }

    // MARK: - cmux vm-tui-connect --config <file>  (runs inside the pane)

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
        defer { if let inviteURL { try? FileManager.default.removeItem(at: inviteURL) } }

        var arguments = ["remote", "connect", config.route, "--device-name", config.deviceName, "--state-dir", config.stateDir]
        if let inviteURL {
            arguments += ["--invite-file", inviteURL.path]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.clientPath)
        process.arguments = arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        cliWriteStderr(String(format: CMUXDiffViewerLocalization.string(
            "cli.vm.tui.connecting",
            defaultValue: "Connecting to %1$@ through cmux-tui…"
        ), config.vmId) + "\n")

        // Foundation spawns the child in its own process group, so the interactive TUI
        // would be a background job of the pane and SIGTTIN-stop on its first tty read.
        // Hand the terminal foreground to the child for its lifetime, as the other
        // interactive-child CLI paths do.
        let originalForegroundProcessGroup = tcgetpgrp(STDIN_FILENO)
        var didForegroundChild = false
        try cliRunProcess(process)
        if originalForegroundProcessGroup > 0 {
            let childProcessGroup = getpgid(process.processIdentifier)
            if childProcessGroup > 0 && childProcessGroup != originalForegroundProcessGroup {
                do {
                    try setTerminalForegroundProcessGroup(childProcessGroup)
                } catch {
                    _ = Darwin.kill(-childProcessGroup, SIGCONT)
                    process.terminate()
                    throw CLIError(message: "vm-tui-connect: couldn't hand the terminal to cmux-tui; aborting to avoid a hang (\(String(describing: error)))")
                }
                _ = Darwin.kill(-childProcessGroup, SIGCONT)
                didForegroundChild = true
            }
        }
        defer {
            if didForegroundChild {
                try? setTerminalForegroundProcessGroup(originalForegroundProcessGroup)
            }
        }

        // While the client claims the invitation, approve the pending enrollment through
        // the app: the control plane minted this invitation for the signed-in user, so
        // approving the claim is the honest encoding of "already authenticated". Nothing
        // is printed while the TUI owns the terminal; the device record is saved silently.
        if let invitationId = config.invitationId, !invitationId.isEmpty {
            let vmId = config.vmId
            let approver = Thread {
                let deadline = Date().addingTimeInterval(Self.vmTuiApprovalTimeoutSeconds)
                while Date() < deadline, process.isRunning {
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
            approver.start()
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            throw CLIError(
                message: String(format: CMUXDiffViewerLocalization.string(
                    "cli.vm.tui.clientExited",
                    defaultValue: "cmux-tui exited with status %1$d. Re-run `cmux vm tui %2$@` to reconnect."
                ), status, config.vmId),
                exitCode: status > 0 ? status : 1
            )
        }
    }
}
