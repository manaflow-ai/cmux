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
        let projectRaw = optionValue(commandArgs, name: "--project")
        let scope = try resolvedArtifactsScope(
            explicit: optionValue(commandArgs, name: "--scope"),
            hasWorkspace: workspaceRaw != nil,
            hasProject: projectRaw != nil
        )
        var params: [String: Any] = ["scope": scope]
        if let workspaceRaw {
            let window = try normalizeWindowHandle(optionValue(commandArgs, name: "--window"), client: client)
            params["workspace_id"] = try resolveWorkspaceId(
                workspaceRaw,
                client: client,
                windowHandle: window
            )
        }
        if let projectRaw { params["project_id"] = projectRaw }

        let payload: [String: Any]
        switch subcommand {
        case "list":
            payload = try client.sendV2(method: "artifacts.list", params: params)
        case "search":
            let query = optionValue(commandArgs, name: "--query")
                ?? artifactsSearchPositionalQuery(commandArgs)
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
                    String(localized: "artifacts.cli.unknownSubcommand", defaultValue: "Unknown artifacts subcommand '%@'. Use list, search, open, or add."),
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
        } else if let artifact = payload["artifact"] as? [String: Any] {
            let id = artifact["id"] as? String ?? "-"
            let kind = artifact["kind"] as? String ?? "artifact"
            let value = (artifact["value"] as? String)
                ?? (artifact["file_name"] as? String)
                ?? (artifact["content"] as? String)?.split(separator: "\n").first.map(String.init)
                ?? "-"
            print("\(kind)\t\(id)\t\(value)")
        } else if let workspaceID = payload["workspace_id"] as? String {
            print(String.localizedStringWithFormat(
                String(localized: "artifacts.cli.openedWorkspace", defaultValue: "Artifacts opened in workspace %@"),
                workspaceID
            ))
        }
        _ = idFormat
    }

    private func artifactsSearchPositionalQuery(_ commandArgs: [String]) -> String? {
        let optionsWithValues: Set<String> = [
            "--workspace",
            "--project",
            "--scope",
            "--window",
            "--query",
            "--limit",
        ]
        var index = 1
        var reachedEndOfOptions = false
        while index < commandArgs.count {
            let argument = commandArgs[index]
            if reachedEndOfOptions {
                return argument
            }
            if argument == "--" {
                reachedEndOfOptions = true
                index += 1
                continue
            }
            guard argument.hasPrefix("--") else { return argument }
            let optionName = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? argument
            if optionsWithValues.contains(optionName), !argument.contains("=") {
                index += 2
            } else {
                index += 1
            }
        }
        return nil
    }

    /// Resolves the catalog scope for one artifacts request.
    ///
    /// An explicit `--scope` wins. Otherwise `--workspace` selects the
    /// workspace scope, `--project` selects the project scope, and the
    /// global catalog is the default. A workspace or project scope without
    /// its id would silently match nothing, so it is rejected up front.
    private func resolvedArtifactsScope(
        explicit: String?,
        hasWorkspace: Bool,
        hasProject: Bool
    ) throws -> String {
        let scope = explicit?.lowercased() ?? (hasWorkspace ? "workspace" : hasProject ? "project" : "global")
        switch scope {
        case "global":
            return scope
        case "workspace":
            guard hasWorkspace else {
                throw CLIError(
                    message: String(localized: "artifacts.cli.workspaceScopeRequiresWorkspace", defaultValue: "Artifacts --scope workspace requires --workspace <id|ref|index>"),
                    exitCode: 2
                )
            }
            return scope
        case "project":
            guard hasProject else {
                throw CLIError(
                    message: String(localized: "artifacts.cli.projectScopeRequiresProject", defaultValue: "Artifacts --scope project requires --project <id>"),
                    exitCode: 2
                )
            }
            return scope
        default:
            throw CLIError(
                message: String.localizedStringWithFormat(
                    String(localized: "artifacts.cli.unknownScope", defaultValue: "Unknown artifacts scope '%@'. Use global, workspace, or project."),
                    scope
                ),
                exitCode: 2
            )
        }
    }
}
