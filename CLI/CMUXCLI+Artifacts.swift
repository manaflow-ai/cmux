import Foundation

extension CMUXCLI {
    /// Drives the canonical Artifacts catalog over the authenticated v2 socket.
    func runArtifactsCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "list"
        let workspaceRaw = optionValue(commandArgs, name: "--workspace")
        let scopeRaw = optionValue(commandArgs, name: "--scope") ?? (workspaceRaw == nil ? "global" : "workspace")
        var params: [String: Any] = ["scope": scopeRaw]
        if let workspaceRaw {
            let window = try normalizeWindowHandle(optionValue(commandArgs, name: "--window"), client: client)
            if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client, windowHandle: window) {
                params["workspace_id"] = workspace
            }
        }
        if let project = optionValue(commandArgs, name: "--project") { params["project_id"] = project }

        let payload: [String: Any]
        switch subcommand {
        case "list":
            payload = try client.sendV2(method: "artifacts.list", params: params)
        case "search":
            let query = optionValue(commandArgs, name: "--query")
                ?? commandArgs.dropFirst().first(where: { !$0.hasPrefix("--") })
                ?? ""
            params["query"] = query
            if let limit = optionValue(commandArgs, name: "--limit"), let value = Int(limit) { params["limit"] = value }
            payload = try client.sendV2(method: "artifacts.search", params: params)
        case "open":
            payload = try client.sendV2(method: "artifacts.open", params: params)
        case "add":
            guard params["workspace_id"] != nil else {
                throw CLIError(
                    message: String(localized: "artifacts.cli.addWorkspaceRequired", defaultValue: "Artifacts add requires --workspace <id|ref|index>"),
                    exitCode: 2
                )
            }
            let inputOptions = [
                ("url", optionValue(commandArgs, name: "--url")),
                ("path", optionValue(commandArgs, name: "--path")),
                ("html", optionValue(commandArgs, name: "--html")),
                ("text", optionValue(commandArgs, name: "--text")),
            ].compactMap { kind, value in value.map { (kind, $0) } }
            guard inputOptions.count == 1 else {
                throw CLIError(
                    message: String(localized: "artifacts.cli.addInputRequired", defaultValue: "Artifacts add requires exactly one of --url, --path, --html, or --text"),
                    exitCode: 2
                )
            }
            params["input_kind"] = inputOptions[0].0
            params["input"] = inputOptions[0].1
            if let kind = optionValue(commandArgs, name: "--kind") { params["kind"] = kind }
            if let title = optionValue(commandArgs, name: "--title") { params["title"] = title }
            if let mimeType = optionValue(commandArgs, name: "--mime-type") { params["mime_type"] = mimeType }
            payload = try client.sendV2(method: "artifacts.add", params: params)
        default:
            throw CLIError(
                message: String.localizedStringWithFormat(
                    String(localized: "artifacts.cli.unknownSubcommand", defaultValue: "Unknown artifacts subcommand '%@'. Use list, search, or open."),
                    subcommand
                ),
                exitCode: 2
            )
        }

        if jsonOutput {
            print(jsonString(payload))
        } else if let artifacts = payload["artifacts"] as? [[String: Any]] {
            for artifact in artifacts {
                let id = artifact["id"] as? String ?? "-"
                let kind = artifact["kind"] as? String ?? "artifact"
                let value = (artifact["value"] as? String)
                    ?? (artifact["file_name"] as? String)
                    ?? (artifact["content"] as? String)?.split(separator: "\n").first.map(String.init)
                    ?? "-"
                print("\(kind)\t\(id)\t\(value)")
            }
        } else if let workspaceID = payload["workspace_id"] as? String {
            print(String.localizedStringWithFormat(
                String(localized: "artifacts.cli.openedWorkspace", defaultValue: "Artifacts opened in workspace %@"),
                workspaceID
            ))
        }
        _ = idFormat
    }
}
