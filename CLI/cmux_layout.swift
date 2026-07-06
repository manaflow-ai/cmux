import Foundation

extension CMUXCLI {
    func runLayoutNamespace(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: "layout requires a subcommand. Try: save, list, get, open, delete")
        }
        let rest = Array(commandArgs.dropFirst())
        switch subcommand {
        case "save":
            try runLayoutSave(commandArgs: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowOverride)
        case "list":
            try runLayoutList(commandArgs: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        case "get":
            try runLayoutGet(commandArgs: rest, client: client)
        case "open":
            try runLayoutOpen(commandArgs: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat, windowOverride: windowOverride)
        case "delete":
            try runLayoutDelete(commandArgs: rest, client: client, jsonOutput: jsonOutput, idFormat: idFormat)
        default:
            throw CLIError(message: "Unknown layout subcommand: \(subcommand). Try: save, list, get, open, delete")
        }
    }

    private func runLayoutSave(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (workspaceOpt, rem0) = parseOption(commandArgs, name: "--workspace")
        let (descriptionOpt, rem1) = parseOption(rem0, name: "--description")
        let (windowOpt, rem2) = parseOption(rem1, name: "--window")
        let overwrite = hasFlag(rem2, name: "--overwrite")
        let remaining = rem2.filter { $0 != "--overwrite" }
        if let unknown = remaining.dropFirst().first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout save: unknown flag '\(unknown)'")
        }
        guard let name = remaining.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "layout save requires <name>")
        }

        let windowHandle = try normalizeWindowHandle(windowOpt ?? windowOverride, client: client)
        let workspaceHandle = try normalizeWorkspaceHandle(
            workspaceOpt,
            client: client,
            windowHandle: windowHandle,
            allowCurrent: true
        )
        var params: [String: Any] = ["name": name]
        if let windowHandle { params["window_id"] = windowHandle }
        if let workspaceHandle { params["workspace_id"] = workspaceHandle }
        if let descriptionOpt { params["description"] = descriptionOpt }
        params["overwrite"] = overwrite

        let payload = try client.sendV2(method: "layout.save", params: params)
        let summary = "OK layout=\(payload["name"] as? String ?? name) unsupported=\(payload["unsupported_surface_count"] ?? 0)"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: summary)
    }

    private func runLayoutList(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if let unknown = commandArgs.first(where: { $0.hasPrefix("--") && $0 != "--json" }) {
            throw CLIError(message: "layout list: unknown flag '\(unknown)'")
        }
        let effectiveJSONOutput = jsonOutput || hasFlag(commandArgs, name: "--json")
        let payload = try client.sendV2(method: "layout.list")
        if effectiveJSONOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let layouts = payload["layouts"] as? [[String: Any]] ?? []
        if layouts.isEmpty {
            print("No saved layouts")
            return
        }
        print("NAME\tPANES\tSURFACES\tDESCRIPTION")
        for layout in layouts {
            let name = layout["name"] as? String ?? ""
            let panes = layout["pane_count"] ?? 0
            let surfaces = layout["surface_count"] ?? 0
            let description = layout["description"] as? String ?? ""
            print("\(name)\t\(panes)\t\(surfaces)\t\(description)")
        }
    }

    private func runLayoutGet(commandArgs: [String], client: SocketClient) throws {
        if let unknown = commandArgs.dropFirst().first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout get: unknown flag '\(unknown)'")
        }
        guard let name = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "layout get requires <name>")
        }
        let payload = try client.sendV2(method: "layout.get", params: ["name": name])
        print(jsonString(payload))
    }

    private func runLayoutOpen(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let (cwdOpt, rem0) = parseOption(commandArgs, name: "--cwd")
        let (focusOpt, rem1) = parseOption(rem0, name: "--focus")
        let (windowOpt, remaining) = parseOption(rem1, name: "--window")
        if let unknown = remaining.dropFirst().first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout open: unknown flag '\(unknown)'")
        }
        guard let name = remaining.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "layout open requires <name>")
        }
        let windowHandle = try normalizeWindowHandle(windowOpt ?? windowOverride, client: client)
        var params: [String: Any] = ["name": name]
        if let windowHandle { params["window_id"] = windowHandle }
        if let cwdOpt { params["cwd"] = resolvePath(cwdOpt) }
        try applyFocusOption(focusOpt, defaultValue: false, to: &params)
        let payload = try client.sendV2(method: "layout.open", params: params)
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: v2CreationSummary(payload, idFormat: idFormat, kinds: ["workspace"]))
    }

    private func runLayoutDelete(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        if let unknown = commandArgs.dropFirst().first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "layout delete: unknown flag '\(unknown)'")
        }
        guard let name = commandArgs.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw CLIError(message: "layout delete requires <name>")
        }
        let payload = try client.sendV2(method: "layout.delete", params: ["name": name])
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: "OK deleted=\(payload["deleted"] ?? true)")
    }
}
