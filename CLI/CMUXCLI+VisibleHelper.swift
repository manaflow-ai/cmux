import Foundation

extension CMUXCLI {
    static let visibleHelperCommandHelp = """
    Usage: cmux visible-helper [flags] [-- <command>]

    Create or reuse a right-side helper pane in the visually focused workspace.

    Flags:
      --type <terminal|browser>    Helper surface type (default: terminal)
      --url <url>                  URL for browser helpers
      --cwd <path>                 Working directory for terminal helpers
      --working-directory <path>   Alias for --cwd
      --command <text>             Initial terminal command
      --window <id|ref|index>      Window context for focused workspace lookup
      --json                       Print structured placement details

    Example:
      cmux visible-helper --command 'pwd'
      cmux visible-helper --type browser --url http://localhost:3000 --json
    """

    func runVisibleHelperCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let options = try parseVisibleHelperOptions(commandArgs)
        var params: [String: Any] = ["target": "focused"]
        if let caller = callerContextFromEnvironment() {
            params["caller"] = caller
        }
        let winId = try normalizeWindowHandle(options.windowHandle ?? windowOverride, client: client)
        if let winId { params["window_id"] = winId }
        if let type = options.type { params["type"] = type }
        if let url = options.url { params["url"] = url }
        if let workingDirectory = options.workingDirectory {
            params["working_directory"] = resolvePath(workingDirectory)
        }
        if let command = options.initialCommand {
            params["initial_command"] = command
        }

        let payload = try client.sendV2(method: "helper.visible", params: params)
        printV2Payload(
            payload,
            jsonOutput: jsonOutput || options.jsonOutput,
            idFormat: idFormat,
            fallbackText: visibleHelperSummary(payload, idFormat: idFormat)
        )
    }

    private struct VisibleHelperOptions {
        let type: String?
        let url: String?
        let workingDirectory: String?
        let initialCommand: String?
        let windowHandle: String?
        let jsonOutput: Bool
    }

    private func parseVisibleHelperOptions(_ args: [String]) throws -> VisibleHelperOptions {
        let (typeOpt, rem0) = parseOption(args, name: "--type")
        let (urlOpt, rem1) = parseOption(rem0, name: "--url")
        let (cwdOpt, rem2) = parseOption(rem1, name: "--cwd")
        let (workingDirectoryOpt, rem3) = parseOption(rem2, name: "--working-directory")
        let (commandOpt, rem4) = parseOption(rem3, name: "--command")
        let (windowOpt, rem5) = parseOption(rem4, name: "--window")

        var jsonOutput = false
        var remaining: [String] = []
        var commandFromTerminator: String?
        var iterator = rem5.makeIterator()
        while let arg = iterator.next() {
            if arg == "--json" {
                jsonOutput = true
                continue
            }
            if arg == "--" {
                var commandParts: [String] = []
                while let commandPart = iterator.next() {
                    commandParts.append(commandPart)
                }
                commandFromTerminator = commandParts.joined(separator: " ")
                break
            }
            remaining.append(arg)
        }

        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "visible-helper: unknown flag '\(unknown)'")
        }
        if let extra = remaining.first {
            throw CLIError(message: "visible-helper: unexpected argument '\(extra)'")
        }
        if commandOpt != nil, commandFromTerminator != nil {
            throw CLIError(message: "visible-helper: pass either --command or -- <command>, not both")
        }

        return VisibleHelperOptions(
            type: typeOpt,
            url: urlOpt,
            workingDirectory: workingDirectoryOpt ?? cwdOpt,
            initialCommand: commandOpt ?? commandFromTerminator?.nilIfEmpty,
            windowHandle: windowOpt,
            jsonOutput: jsonOutput
        )
    }

    private func callerContextFromEnvironment() -> [String: Any]? {
        let environment = ProcessInfo.processInfo.environment
        var caller: [String: Any] = [:]
        if let workspace = environment["CMUX_WORKSPACE_ID"]?.nilIfEmpty {
            caller["workspace_id"] = workspace
        }
        if let surface = (environment["CMUX_SURFACE_ID"] ?? environment["CMUX_TAB_ID"])?.nilIfEmpty {
            caller["surface_id"] = surface
            caller["tab_id"] = surface
        }
        return caller.isEmpty ? nil : caller
    }

    private func visibleHelperSummary(_ payload: [String: Any], idFormat: CLIIDFormat) -> String {
        var parts = ["OK", "target=focused"]
        if let workspace = formatHandle(payload, kind: "workspace", idFormat: idFormat) {
            parts.append("workspace=\(workspace)")
        }
        if let pane = formatHandle(payload, kind: "pane", idFormat: idFormat) {
            parts.append("pane=\(pane)")
        }
        if let surface = formatHandle(payload, kind: "surface", idFormat: idFormat) {
            parts.append("surface=\(surface)")
        }
        if let strategy = payload["placement_strategy"] as? String {
            parts.append("strategy=\(strategy)")
        }
        if let diverged = payload["caller_focused_diverged"] as? Bool {
            parts.append("caller_focused_diverged=\(diverged ? "true" : "false")")
        }
        return parts.joined(separator: " ")
    }
}
