import Foundation

extension CMUXCLI {
    static var textBoxUsage: String {
        String(
            localized: "cli.textbox.usage",
            defaultValue: "Usage: cmux textbox <toggle|show|hide|state> [--surface <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus] [--json]"
        )
    }

    static var textBoxHelp: String {
        String(localized: "cli.help.textbox", defaultValue: """
        Usage: cmux textbox <toggle|show|hide|state> [flags]

        Show, hide, or toggle a terminal's TextBox Input, like the Toggle TextBox Input command. The TextBox appears without taking keyboard focus; hide keeps its draft. state reports it without changing it. Prints OK <surface> <workspace> visible=<true|false>; --json adds changed.

        Flags:
          --surface <id|ref|index>     Target terminal (default: $CMUX_SURFACE_ID, then the focused terminal)
          --panel <id|ref|index>       Alias for --surface
          --workspace <id|ref|index>   Workspace context (default: $CMUX_WORKSPACE_ID)
          --window <id|ref|index>      Window context for workspace/surface refs and indexes
          --focus                      Focus the TextBox after showing it (toggle and show only)
          --json                       Print JSON
        """)
    }

    /// `cmux textbox <toggle|show|hide|state>`: the `surface.textbox.*` socket
    /// methods. The app resolves the terminal and applies the action; the CLI
    /// only picks the target, defaulting to the calling terminal.
    func runTextBox(
        commandArgs: [String],
        client: SocketClient,
        windowOverride: String?,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let (workspaceRaw, afterWorkspace) = parseOption(commandArgs, name: "--workspace")
        let (surfaceOption, afterSurface) = parseOption(afterWorkspace, name: "--surface")
        let (panelOption, afterPanel) = parseOption(afterSurface, name: "--panel")
        let (windowOption, afterWindow) = parseOption(afterPanel, name: "--window")
        let focus = afterWindow.contains("--focus")
        let positional = afterWindow.filter { $0 != "--focus" && $0 != "--" }
        guard positional.count == 1,
              let verb = positional.first?.lowercased(),
              ["toggle", "show", "hide", "state"].contains(verb) else {
            throw CLIError(message: Self.textBoxUsage)
        }
        if focus, verb == "hide" || verb == "state" {
            throw CLIError(message: Self.textBoxUsage)
        }

        let windowRaw = windowOption ?? windowOverride
        let explicitSurface = surfaceOption ?? panelOption
        // With no target, act on the calling terminal rather than whichever
        // terminal the user has focused, unless the caller scoped the request
        // to another window or workspace.
        let surfaceRaw = explicitSurface ?? (windowRaw == nil && workspaceRaw == nil
            ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
            : nil)
        let workspaceArg = workspaceRaw
            ?? callerWorkspace(owningSurface: surfaceRaw, windowRaw: windowRaw, client: client)

        var params: [String: Any] = [:]
        let windowId = try normalizeWindowHandle(windowRaw, client: client)
        if let windowId { params["window_id"] = windowId }
        let workspaceId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: windowId)
        if let workspaceId { params["workspace_id"] = workspaceId }
        let surfaceId = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            workspaceHandle: workspaceId,
            windowHandle: windowId
        )
        if let surfaceId { params["surface_id"] = surfaceId }
        if focus { params["focus"] = true }

        let payload = try client.sendV2(method: "surface.textbox.\(verb)", params: params)
        let visible = (payload["visible"] as? Bool) ?? false
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: "\(v2OKSummary(payload, idFormat: idFormat)) visible=\(visible)"
        )
    }
}
