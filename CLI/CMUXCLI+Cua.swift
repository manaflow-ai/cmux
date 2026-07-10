import Foundation

extension CMUXCLI {
    func runCua(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            print(cuaUsage())
            return
        }
        if subcommand == "help" {
            print(cuaUsage())
            return
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        switch subcommand {
        case "status":
            try requireCuaArgumentCount(commandArgs, count: 1, usage: "cmux cua status [--json]")
            let payload = try client.sendV2(method: "cua.status")
            printCuaPayload(payload, jsonOutput: jsonOutput)
        case "ensure":
            try requireCuaArgumentCount(commandArgs, count: 1, usage: "cmux cua ensure [--json]")
            let payload = try client.sendV2(method: "cua.ensure")
            printCuaPayload(payload, jsonOutput: jsonOutput)
        case "setup":
            try requireCuaArgumentCount(commandArgs, count: 1, usage: "cmux cua setup [--json]")
            try runCuaSetup(client: client, jsonOutput: jsonOutput)
        case "grant":
            guard commandArgs.count == 2, let permission = cuaPermission(commandArgs[1]) else {
                throw CLIError(message: "Usage: cmux cua grant <accessibility|screen-recording>")
            }
            let payload = try client.sendV2(method: "cua.grant", params: ["permission": permission.socketValue])
            if jsonOutput {
                print(jsonString(payload))
            } else {
                printCuaGrant(payload, permission: permission)
            }
        case "open-settings":
            guard commandArgs.count == 2, let permission = cuaPermission(commandArgs[1]) else {
                throw CLIError(message: "Usage: cmux cua open-settings <accessibility|screen-recording>")
            }
            let payload = try client.sendV2(
                method: "cua.openSystemSettings",
                params: ["permission": permission.socketValue]
            )
            if jsonOutput {
                print(jsonString(payload))
            } else {
                print("Opened System Settings for \(permission.displayName).")
            }
        default:
            throw CLIError(message: "Unknown cua subcommand '\(subcommand)'. Run 'cmux cua --help'.")
        }
    }

    func cuaUsage() -> String {
        """
        Usage: cmux cua <command> [options]

        Check and configure Computer Use for cmux.

        Commands:
          status [--json]                         Show permissions and driver readiness.
          setup [--json]                          Prompt for missing permissions, then test the driver.
          ensure [--json]                         Ensure the driver is running and report its handshake.
          grant <accessibility|screen-recording>  Prompt for one permission.
          open-settings <accessibility|screen-recording>
                                                   Open the matching System Settings privacy pane.
        """
    }

    private func runCuaSetup(client: SocketClient, jsonOutput: Bool) throws {
        let initial = try client.sendV2(method: "cua.status")
        let permissions = initial["permissions"] as? [String: Any] ?? [:]
        var grants: [String: Any] = [:]

        for permission in CuaCLIPermission.allCases where permissions[permission.socketValue] as? Bool != true {
            let grant = try client.sendV2(
                method: "cua.grant",
                params: ["permission": permission.socketValue]
            )
            grants[permission.socketValue] = grant
            if !jsonOutput {
                printCuaGrant(grant, permission: permission)
                if grant["granted"] as? Bool != true {
                    print("  Run `cmux cua open-settings \(permission.cliValue)` (cua.openSystemSettings).")
                }
                if permission == .screenRecording {
                    print("  Screen Recording changes require relaunching cmux to take effect.")
                }
            }
        }

        if !jsonOutput, grants.isEmpty {
            print("Permissions: already granted.")
        }

        let ensured = try client.sendV2(method: "cua.ensure")
        if jsonOutput {
            print(jsonString([
                "status": initial,
                "grants": grants,
                "ensure": ensured,
            ]))
        } else {
            printCuaPayload(ensured, jsonOutput: false)
        }
    }

    private func printCuaPayload(_ payload: [String: Any], jsonOutput: Bool) {
        if jsonOutput {
            print(jsonString(payload))
            return
        }

        let permissions = payload["permissions"] as? [String: Any] ?? [:]
        print("Permissions:")
        print("  \(cuaCheckmark(permissions["accessibility"] as? Bool == true)) Accessibility")
        print("  \(cuaCheckmark(permissions["screenRecording"] as? Bool == true)) Screen Recording")

        let driver = payload["driver"] as? [String: Any] ?? [:]
        let state = driver["state"] as? String ?? "unknown"
        print("Driver: \(cuaDriverSummary(driver, state: state))")
        if let path = driver["resolvedPath"] as? String {
            let source = driver["resolutionSource"] as? String ?? "unknown"
            print("Resolved binary: \(path) (\(source))")
        } else {
            print("Resolved binary: not found")
        }
    }

    private func printCuaGrant(_ payload: [String: Any], permission: CuaCLIPermission) {
        if payload["granted"] as? Bool == true {
            print("\(permission.displayName): granted.")
        } else {
            print("\(permission.displayName): prompt requested; not granted yet.")
        }
    }

    private func cuaDriverSummary(_ driver: [String: Any], state: String) -> String {
        switch state {
        case "running":
            let pid = intFromAny(driver["pid"]).map(String.init) ?? "unknown"
            let tools = intFromAny(driver["toolCount"]).map(String.init) ?? "unknown"
            let server = [driver["serverName"] as? String, driver["serverVersion"] as? String]
                .compactMap { $0 }
                .joined(separator: " ")
            let prefix = server.isEmpty ? "ready" : "ready (\(server))"
            return "\(prefix), PID \(pid), \(tools) tools"
        case "failed":
            return "failed: \(driver["failureReason"] as? String ?? "unknown error")"
        case "notFound":
            return "not found"
        case "idle":
            return "idle"
        case "starting":
            return "checking readiness"
        default:
            return state
        }
    }

    private func cuaCheckmark(_ granted: Bool) -> String {
        granted ? "✓" : "✗"
    }

    private func cuaPermission(_ raw: String) -> CuaCLIPermission? {
        CuaCLIPermission.allCases.first { $0.cliValue == raw.lowercased() }
    }

    private func requireCuaArgumentCount(_ arguments: [String], count: Int, usage: String) throws {
        guard arguments.count == count else {
            throw CLIError(message: "Usage: \(usage)")
        }
    }
}

private enum CuaCLIPermission: CaseIterable {
    case accessibility
    case screenRecording

    var cliValue: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "screen-recording"
        }
    }

    var socketValue: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "screenRecording"
        }
    }

    var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }
}
