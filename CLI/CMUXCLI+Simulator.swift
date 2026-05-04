import Foundation

extension CMUXCLI {
    func runSimulatorCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let sub = commandArgs.first?.lowercased() ?? ""
        let rest = sub.isEmpty ? commandArgs : Array(commandArgs.dropFirst())

        switch sub {
        case "", "tui", "ui":
            try runSimulatorTUI(client: client, idFormat: idFormat, jsonOutput: jsonOutput)
        case "list", "ls":
            try runSimulatorList(client: client, jsonOutput: jsonOutput)
        case "boot":
            try runSimulatorLifecycle(method: "simulator.boot", args: rest, client: client, jsonOutput: jsonOutput, verb: "boot")
        case "shutdown", "stop":
            try runSimulatorLifecycle(method: "simulator.shutdown", args: rest, client: client, jsonOutput: jsonOutput, verb: "shutdown")
        case "open":
            try runSimulatorOpen(commandArgs: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "Unknown sim subcommand: \(sub). Usage: cmux sim [open|list|boot|shutdown] (no args = interactive)")
        }
    }

    func runSimulatorList(client: SocketClient, jsonOutput: Bool) throws {
        let payload = try client.sendV2(method: "simulator.list", params: [:])
        let devices = (payload["devices"] as? [[String: Any]]) ?? []
        if jsonOutput {
            print(jsonString(payload))
            return
        }
        let grouped = Dictionary(grouping: devices) { ($0["runtime"] as? String) ?? "Other" }
        for runtime in grouped.keys.sorted() {
            print(runtime.isEmpty ? "Other" : runtime)
            let rows = (grouped[runtime] ?? []).sorted {
                ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "")
            }
            for row in rows {
                let name = (row["name"] as? String) ?? "?"
                let state = (row["state"] as? String) ?? "?"
                let udid = (row["udid"] as? String) ?? ""
                print("  \(state == "booted" ? "●" : "○") \(name)  \(udid)  [\(state)]")
            }
        }
    }

    private func runSimulatorLifecycle(
        method: String,
        args: [String],
        client: SocketClient,
        jsonOutput: Bool,
        verb: String
    ) throws {
        let (udidOpt, rest) = parseOption(args, name: "--udid")
        let udid = udidOpt ?? rest.first
        guard let udid, !udid.isEmpty else {
            throw CLIError(message: "sim \(verb) requires a UDID. Usage: cmux sim \(verb) <udid>")
        }
        let payload = try client.sendV2(method: method, params: ["udid": udid])
        if jsonOutput {
            print(jsonString(payload))
        } else {
            print("OK \(verb) udid=\(udid)")
        }
    }

    private func runSimulatorOpen(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        var args = commandArgs
        let (workspaceOpt, argsAfterWorkspace) = parseOption(args, name: "--workspace")
        let (windowOpt, argsAfterWindow) = parseOption(argsAfterWorkspace, name: "--window")
        let (surfaceOpt, argsAfterSurface) = parseOption(argsAfterWindow, name: "--surface")
        let (directionOpt, argsAfterDirection) = parseOption(argsAfterSurface, name: "--direction")
        let (udidOpt, argsAfterUDID) = parseOption(argsAfterDirection, name: "--udid")
        args = argsAfterUDID

        if let unknownFlag = args.first(where: { $0.hasPrefix("-") }) {
            throw CLIError(
                message:
                    "sim open: unknown flag '\(unknownFlag)'. Usage: cmux sim open [--udid <udid>] [--direction right|down|left|up]"
            )
        }
        if let extraArg = args.first {
            throw CLIError(
                message:
                    "sim open: unexpected argument '\(extraArg)'. Usage: cmux sim open [--udid <udid>] [--direction right|down|left|up]"
            )
        }

        let direction = directionOpt ?? "right"
        var params: [String: Any] = ["direction": direction]
        if let udid = udidOpt, !udid.isEmpty {
            params["udid"] = udid
        }
        if let surfaceRaw = surfaceOpt {
            if let surface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = surface
            }
        }
        let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        if let workspaceRaw {
            if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                params["workspace_id"] = workspace
            }
        }
        if let windowRaw = windowOpt {
            if let window = try normalizeWindowHandle(windowRaw, client: client) {
                params["window_id"] = window
            }
        }

        let payload = try client.sendV2(method: "simulator.open", params: params)

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: idFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: idFormat) ?? "unknown"
            let udidText = (payload["udid"] as? String) ?? "(none)"
            print("OK surface=\(surfaceText) pane=\(paneText) udid=\(udidText)")
        }
    }
}
