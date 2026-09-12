import Foundation
import CmuxControlSocket

extension CMUXCLI {
    /// Sends a connection-local terminal viewport override or reset.
    ///
    /// The socket connection remains the owner of the override. A standalone
    /// CLI invocation therefore reports the applied projection and disconnects;
    /// persistent clients should send the same v2 methods over their long-lived
    /// socket when they need the override to survive multiple reads.
    func runTerminalViewportCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let subcommand = commandArgs.first?.lowercased() ?? "help"
        guard subcommand == "viewport" else {
            throw CLIError(message: Self.terminalViewportUsage)
        }
        let remainder = Array(commandArgs.dropFirst())
        let (surfaceOpt, afterSurface) = parseOption(remainder, name: "--surface")
        let (workspaceOpt, afterWorkspace) = parseOption(afterSurface, name: "--workspace")
        let (windowOpt, afterWindow) = parseOption(afterWorkspace, name: "--window")
        let (widthOpt, afterWidth) = parseOption(afterWindow, name: "--width")
        let (heightOpt, afterHeight) = parseOption(afterWidth, name: "--height")
        let pixels = hasFlag(afterHeight, name: "--pixels")
        let positional = afterHeight.filter { $0 != "--pixels" }

        var params: [String: Any] = [:]
        let windowRaw = windowOpt ?? windowOverride
        let workspaceRaw = workspaceOpt
            ?? Self.callerWorkspaceForSurfaceHandle(surfaceOpt, windowRaw: windowRaw)
        let surfaceRaw = surfaceOpt
            ?? (workspaceOpt == nil && windowRaw == nil
                ? ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]
                : nil)
        let windowID = try normalizeWindowHandle(windowRaw, client: client)
        if let windowID { params["window_id"] = windowID }
        let workspaceID = try normalizeWorkspaceHandle(
            workspaceRaw,
            client: client,
            windowHandle: windowID
        )
        if let workspaceID { params["workspace_id"] = workspaceID }
        let surfaceID = try normalizeSurfaceHandle(
            surfaceRaw,
            client: client,
            workspaceHandle: workspaceID,
            windowHandle: windowID
        )
        if let surfaceID { params["surface_id"] = surfaceID }

        if positional.first?.lowercased() == "reset" {
            guard positional.count == 1,
                  widthOpt == nil,
                  heightOpt == nil,
                  !pixels else {
                throw CLIError(message: Self.terminalViewportResetUsage)
            }
            let payload = try client.sendV2(method: "terminal.viewport.reset", params: params)
            printV2Payload(
                payload,
                jsonOutput: jsonOutput,
                idFormat: idFormat,
                fallbackText: v2OKSummary(payload, idFormat: idFormat)
            )
            return
        }

        if let widthOpt, let heightOpt {
            guard positional.isEmpty,
                  let width = Int(widthOpt),
                  let height = Int(heightOpt) else {
                throw CLIError(message: Self.terminalViewportUsage)
            }
            params["width"] = width
            params["height"] = height
            if pixels { params["pixels"] = true }
        } else {
            guard widthOpt == nil,
                  heightOpt == nil,
                  !pixels,
                  positional.count == 2,
                  let parsedColumns = Int(positional[0]),
                  let parsedRows = Int(positional[1]) else {
                throw CLIError(message: Self.terminalViewportUsage)
            }
            params["columns"] = parsedColumns
            params["rows"] = parsedRows
        }

        let payload = try client.sendV2(method: "terminal.viewport.set", params: params)
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: v2OKSummary(payload, idFormat: idFormat)
        )
    }

    static let terminalViewportUsage = String(
        localized: "cli.terminal.viewport.usage",
        defaultValue: "Usage: cmux terminal viewport <columns> <rows> [--surface <id>] | reset\n       cmux terminal viewport --width <pixels> --height <pixels> [--surface <id>] [--pixels]"
    )

    static let terminalViewportCommandLine = String(
        localized: "cli.terminal.viewport.commandLine",
        defaultValue: "terminal viewport <columns> <rows> [--surface <id>] | reset"
    )

    static let terminalViewportResetUsage = String(
        localized: "cli.terminal.viewport.resetUsage",
        defaultValue: "terminal viewport reset does not accept dimensions or additional arguments"
    )

    static let terminalViewportHelp = String(
        localized: "cli.terminal.viewport.help",
        defaultValue: "Set or reset a per-connection terminal render viewport. The PTY and Mac pane are not resized; the override is cleared when this socket disconnects."
    )
}
