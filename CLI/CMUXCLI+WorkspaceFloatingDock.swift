import Foundation

/// `cmux workspace float`: agent-visible control for workspace-scoped floating Docks.
extension CMUXCLI {
    func runWorkspaceFloatingDock(
        commandArgs: [String], client: SocketClient, jsonOutput: Bool,
        idFormat: CLIIDFormat, windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.workspaceFloatingDockUsage)
            return
        }
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: floatingDockCLIString(
                "cli.workspace.float.error.subcommandRequired",
                defaultValue: "workspace float requires a subcommand. Try: list, create, show, hide, focus, close, close-all, frame, color, note, surface, pane"
            ))
        }
        let target = try workspaceFloatingDockTarget(
            Array(commandArgs.dropFirst()), client: client, windowOverride: windowOverride
        )
        var params = target.params
        let args = target.rest

        switch subcommand {
        case "list", "ls":
            let payload = try client.sendV2(method: "workspace.float.list", params: params)
            printFloatingDockList(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "create":
            let (title, rem0) = parseOption(args, name: "--title")
            let (kind, rem1) = parseOption(rem0, name: "--type")
            let (url, rem2) = parseOption(rem1, name: "--url")
            let (color, rem3) = parseOption(rem2, name: "--color")
            let (relativeTo, rem4) = parseOption(rem3, name: "--relative-to")
            if let title { params["title"] = title }
            params["kind"] = kind ?? "terminal"
            if let url { params["url"] = url }
            if let color { params["color"] = color }
            if let relativeTo { params["relative_to"] = relativeTo }
            params["focus"] = hasFlag(rem4, name: "--focus")
            try addFloatingDockFrameParams(from: rem4, to: &params, required: false)
            let payload = try client.sendV2(method: "workspace.float.create", params: params)
            printFloatingDockMutation(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "show", "hide", "focus", "close":
            let (selector, remaining) = try floatingDockSelector(from: args)
            params["float"] = selector
            if subcommand == "show" { params["focus"] = hasFlag(remaining, name: "--focus") }
            let payload = try client.sendV2(method: "workspace.float.\(subcommand)", params: params)
            printFloatingDockMutation(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "close-all", "close_all":
            let payload = try client.sendV2(method: "workspace.float.close_all", params: params)
            if jsonOutput {
                printV2Payload(payload, jsonOutput: true, idFormat: idFormat, fallbackText: "")
            } else {
                let closedCount = (payload["closed_count"] as? NSNumber)?.intValue ?? 0
                print(String(
                    format: floatingDockCLIString(
                        "cli.workspace.float.output.closedAll",
                        defaultValue: "Closed %d floating window(s)."
                    ),
                    locale: .current,
                    closedCount
                ))
            }
        case "frame":
            let (selector, remaining) = try floatingDockSelector(from: args)
            params["float"] = selector
            try addFloatingDockFrameParams(from: remaining, to: &params, required: true)
            let payload = try client.sendV2(method: "workspace.float.set_frame", params: params)
            printFloatingDockMutation(payload, jsonOutput: jsonOutput, idFormat: idFormat)
        case "color":
            try runWorkspaceFloatingDockColor(
                args: args, params: params, client: client, jsonOutput: jsonOutput, idFormat: idFormat
            )
        case "note":
            try runWorkspaceFloatingDockNote(
                args: args, params: params, client: client, jsonOutput: jsonOutput, idFormat: idFormat
            )
        case "surface":
            try runWorkspaceFloatingDockSurface(
                args: args, params: params, client: client, jsonOutput: jsonOutput, idFormat: idFormat
            )
        case "pane":
            try runWorkspaceFloatingDockPane(
                args: args, params: params, client: client, jsonOutput: jsonOutput, idFormat: idFormat
            )
        default:
            throw CLIError(message: String(
                format: floatingDockCLIString(
                    "cli.workspace.float.error.subcommandUnknown",
                    defaultValue: "Unknown workspace float subcommand: %@"
                ),
                locale: .current,
                subcommand
            ))
        }
    }

    private func workspaceFloatingDockTarget(
        _ args: [String], client: SocketClient, windowOverride: String?
    ) throws -> (params: [String: Any], rest: [String]) {
        let (workspaceRaw, rem0) = parseOption(args, name: "--workspace")
        let (windowRaw, rem1) = parseOption(rem0, name: "--window")
        var params: [String: Any] = [:]
        let window = try normalizeWindowHandle(windowRaw ?? windowOverride, client: client)
        if let window { params["window_id"] = window }
        if let workspace = try normalizeWorkspaceHandle(
            workspaceRaw, client: client, windowHandle: window, allowCurrent: true
        ) { params["workspace_id"] = workspace }
        return (params, rem1.filter { $0 != "--json" })
    }

    private func floatingDockSelector(from args: [String]) throws -> (String, [String]) {
        let (option, remaining) = parseOption(args, name: "--float")
        if let option { return (option, remaining) }
        guard let index = remaining.firstIndex(where: { !$0.hasPrefix("-") }) else {
            throw CLIError(message: floatingDockCLIString(
                "cli.workspace.float.error.selectorRequired",
                defaultValue: "A floating Dock selector is required (UUID, float:N, or 1-based index)"
            ))
        }
        var rest = remaining
        return (rest.remove(at: index), rest)
    }

    private func addFloatingDockFrameParams(
        from args: [String], to params: inout [String: Any], required: Bool
    ) throws {
        var rest = args
        var values: [String: Double] = [:]
        for key in ["x", "y", "width", "height"] {
            let (raw, next) = parseOption(rest, name: "--\(key)")
            rest = next
            if let raw {
                guard let value = Double(raw), value.isFinite else {
                    throw CLIError(message: String(
                        format: floatingDockCLIString(
                            "cli.workspace.float.error.finiteNumber",
                            defaultValue: "--%@ must be a finite number"
                        ),
                        locale: .current,
                        key
                    ))
                }
                values[key] = value
            }
        }
        guard required || !values.isEmpty else { return }
        guard values.count == 4 else {
            throw CLIError(message: floatingDockCLIString(
                "cli.workspace.float.error.completeFrame",
                defaultValue: "--x, --y, --width, and --height must be supplied together"
            ))
        }
        for (key, value) in values { params[key] = value }
    }

    private func runWorkspaceFloatingDockNote(
        args: [String], params initialParams: [String: Any], client: SocketClient,
        jsonOutput: Bool, idFormat: CLIIDFormat
    ) throws {
        guard let verb = args.first?.lowercased(), verb == "get" || verb == "set" else {
            throw CLIError(message: floatingDockCLIString(
                "cli.workspace.float.error.noteUsage",
                defaultValue: "Usage: cmux workspace float note <get|set> <float> [text]"
            ))
        }
        let (selector, remaining) = try floatingDockSelector(from: Array(args.dropFirst()))
        var params = initialParams
        params["float"] = selector
        if verb == "set" {
            let positional = remaining.filter { !$0.hasPrefix("--") }
            let text: String
            if !positional.isEmpty {
                text = positional.joined(separator: " ")
            } else if isatty(STDIN_FILENO) == 0 {
                var lines: [String] = []
                while let line = readLine(strippingNewline: false) { lines.append(line) }
                text = lines.joined()
            } else {
                throw CLIError(message: floatingDockCLIString(
                    "cli.workspace.float.error.noteSetUsage",
                    defaultValue: "Usage: cmux workspace float note set <float> <text> (or pipe text on stdin)"
                ))
            }
            params["text"] = text
        }
        let payload = try client.sendV2(method: "workspace.float.note.\(verb)", params: params)
        if jsonOutput { print(jsonString(formatIDs(payload, mode: idFormat))) }
        else if verb == "get" { print(payload["text"] as? String ?? "") }
        else { print("OK") }
    }

    private func runWorkspaceFloatingDockColor(
        args: [String], params initialParams: [String: Any], client: SocketClient,
        jsonOutput: Bool, idFormat: CLIIDFormat
    ) throws {
        guard let verb = args.first?.lowercased(), ["get", "set", "reset"].contains(verb) else {
            throw CLIError(message: floatingDockCLIString(
                "cli.workspace.float.error.colorUsage",
                defaultValue: "Usage: cmux workspace float color <get|set|reset> <float> [--color #RRGGBB]"
            ))
        }
        let (selector, remaining) = try floatingDockSelector(from: Array(args.dropFirst()))
        var params = initialParams
        params["float"] = selector
        if verb == "set" {
            let (color, _) = parseOption(remaining, name: "--color")
            guard let color else {
                throw CLIError(message: floatingDockCLIString(
                    "cli.workspace.float.error.colorRequired",
                    defaultValue: "--color #RRGGBB is required"
                ))
            }
            params["color"] = color
        }
        let payload = try client.sendV2(method: "workspace.float.color.\(verb)", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else if verb == "get" {
            print(payload["background_color"] as? String ?? floatingDockCLIString(
                "cli.workspace.float.output.defaultColor",
                defaultValue: "default"
            ))
        } else {
            printFloatingDockMutation(payload, jsonOutput: false, idFormat: idFormat)
        }
    }

    private func runWorkspaceFloatingDockSurface(
        args: [String], params initialParams: [String: Any], client: SocketClient,
        jsonOutput: Bool, idFormat: CLIIDFormat
    ) throws {
        guard args.first?.lowercased() == "create" else {
            throw CLIError(message: floatingDockCLIString(
                "cli.workspace.float.error.surfaceUsage",
                defaultValue: "Usage: cmux workspace float surface create <float> --type <terminal|browser>"
            ))
        }
        let (selector, selectorRest) = try floatingDockSelector(from: Array(args.dropFirst()))
        let (kind, rem0) = parseOption(selectorRest, name: "--type")
        let (pane, rem1) = parseOption(rem0, name: "--pane")
        let (url, rem2) = parseOption(rem1, name: "--url")
        guard let kind else { throw CLIError(message: floatingDockCLIString(
            "cli.workspace.float.error.typeRequired",
            defaultValue: "--type terminal|browser is required"
        )) }
        var params = initialParams
        params["float"] = selector; params["kind"] = kind
        if let pane { params["pane_id"] = pane }
        if let url { params["url"] = url }
        params["focus"] = hasFlag(rem2, name: "--focus")
        let payload = try client.sendV2(method: "workspace.float.surface.create", params: params)
        printFloatingDockMutation(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    private func runWorkspaceFloatingDockPane(
        args: [String], params initialParams: [String: Any], client: SocketClient,
        jsonOutput: Bool, idFormat: CLIIDFormat
    ) throws {
        guard args.first?.lowercased() == "create" else {
            throw CLIError(message: floatingDockCLIString(
                "cli.workspace.float.error.paneUsage",
                defaultValue: "Usage: cmux workspace float pane create <float> --type <terminal|browser> [--direction right]"
            ))
        }
        let (selector, selectorRest) = try floatingDockSelector(from: Array(args.dropFirst()))
        let (kind, rem0) = parseOption(selectorRest, name: "--type")
        let (direction, rem1) = parseOption(rem0, name: "--direction")
        let (surface, rem2) = parseOption(rem1, name: "--surface")
        let (url, rem3) = parseOption(rem2, name: "--url")
        guard let kind else { throw CLIError(message: floatingDockCLIString(
            "cli.workspace.float.error.typeRequired",
            defaultValue: "--type terminal|browser is required"
        )) }
        var params = initialParams
        params["float"] = selector; params["kind"] = kind
        params["direction"] = direction ?? "right"
        if let surface { params["surface_id"] = surface }
        if let url { params["url"] = url }
        params["focus"] = hasFlag(rem3, name: "--focus")
        let payload = try client.sendV2(method: "workspace.float.pane.create", params: params)
        printFloatingDockMutation(payload, jsonOutput: jsonOutput, idFormat: idFormat)
    }

    private func printFloatingDockList(_ payload: [String: Any], jsonOutput: Bool, idFormat: CLIIDFormat) {
        if jsonOutput { print(jsonString(formatIDs(payload, mode: idFormat))); return }
        let floats = payload["floats"] as? [[String: Any]] ?? []
        guard !floats.isEmpty else {
            print(floatingDockCLIString(
                "cli.workspace.float.output.empty",
                defaultValue: "No floating Docks."
            ))
            return
        }
        for item in floats {
            let ref = item["ref"] as? String ?? "float:?"
            let title = item["title"] as? String ?? String(
                localized: "floatingDock.defaultTitle", defaultValue: "Notes"
            )
            let state = (item["visible"] as? Bool) == true
                ? floatingDockCLIString("cli.workspace.float.output.visible", defaultValue: "visible")
                : floatingDockCLIString("cli.workspace.float.output.hidden", defaultValue: "hidden")
            let panes = (item["panes"] as? [[String: Any]])?.count ?? 0
            let format = floatingDockCLIString(
                "cli.workspace.float.output.row",
                defaultValue: "%1$@  %2$@  %3$@  %4$d pane(s)"
            )
            print(String(format: format, locale: .current, ref, title, state, panes))
        }
    }

    private func printFloatingDockMutation(_ payload: [String: Any], jsonOutput: Bool, idFormat: CLIIDFormat) {
        let fallback = (payload["ref"] as? String).map { "OK \($0)" } ?? "OK"
        printV2Payload(payload, jsonOutput: jsonOutput, idFormat: idFormat, fallbackText: fallback)
    }

    private func floatingDockCLIString(
        _ key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        String(localized: key, defaultValue: defaultValue)
    }

    static let workspaceFloatingDockUsage = String(localized: "cli.workspace.float.usage", defaultValue: """
    Usage: cmux workspace float <subcommand> [flags]

    Manage window-like Bonsplit containers scoped to one workspace. Targets the
    caller's workspace by default. A float selector is a UUID, float:N, or the
    1-based index printed by list. Mutations preserve focus unless --focus is set.

    Subcommands:
      list
      create [--type terminal|browser|notes] [--title <title>] [--url <URL>]
             [--color #RRGGBB] [--relative-to <float>]
             [--x N --y N --width N --height N] [--focus]
      show <float> [--focus] | hide <float> | focus <float> | close <float> | close-all
      frame <float> --x N --y N --width N --height N
      color get <float> | color set <float> --color #RRGGBB | color reset <float>
      note get <float> | note set <float> <text>
      surface create <float> --type terminal|browser [--pane <UUID>] [--url <URL>] [--focus]
      pane create <float> --type terminal|browser [--surface <UUID>]
                  [--direction left|right|up|down] [--url <URL>] [--focus]

    Shared flags: --workspace <id|ref|index>, --window <id|ref|index>, --json
    """)
}
