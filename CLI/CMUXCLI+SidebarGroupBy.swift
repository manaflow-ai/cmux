import Foundation

/// `cmux sidebar-group-by`: prints or sets a window's sidebar Group By mode.
struct SidebarGroupByCommand {
    // One escaped literal instead of a multi-line string: scripts/localize-changes
    // reads single-line defaultValue literals only.
    static let usage = String(
        localized: "cli.sidebarGroupBy.usage",
        defaultValue: "Usage: cmux sidebar-group-by [manual|host|status] [--window <id|ref|index>] [--json]\n\nPrint or set how a window's workspace sidebar is grouped.\n\nModes:\n  manual   Your own order and workspace groups (default)\n  host     One section per machine: this Mac, each SSH host, each Cloud VM\n  status   Needs input, running, unread, idle, then plain terminals\n\nWithout a mode, prints the current mode. Host and Status never change\nyour manual groups or order. The window is not focused.\n\nFlags:\n  --window <id|ref|index>   Target window (default: the caller's window)\n  --json                    Print the window id and mode as JSON\n\nExamples:\n  cmux sidebar-group-by\n  cmux sidebar-group-by host\n  cmux sidebar-group-by manual --window window:2"
    )

    /// The requested mode, lowercased; nil only reads the current mode.
    let mode: String?
    /// The `--window` value after the command name, if any.
    let window: String?

    init(arguments args: [String]) throws {
        var mode: String?
        var window: String?
        var index = 0
        while index < args.count {
            let argument = args[index]
            if argument == "--window" {
                index += 1
                guard index < args.count else {
                    throw CLIError(message: String(
                        localized: "cli.sidebarGroupBy.error.window",
                        defaultValue: "sidebar-group-by: --window requires a window id, ref or index"
                    ))
                }
                window = args[index]
            } else if argument.hasPrefix("--window=") {
                window = String(argument.dropFirst("--window=".count))
            } else if mode == nil, !argument.hasPrefix("-") {
                // The app owns the list of modes and rejects an unknown one.
                mode = argument.lowercased()
            } else {
                throw CLIError(message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.sidebarGroupBy.error.argument",
                        defaultValue: "sidebar-group-by: unexpected argument '%@'. Run 'cmux sidebar-group-by --help'."
                    ),
                    argument
                ))
            }
            index += 1
        }
        self.mode = mode
        self.window = window
    }
}

extension CMUXCLI {
    func runSidebarGroupByCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let command = try SidebarGroupByCommand(arguments: commandArgs)
        var params: [String: Any] = [:]
        if let mode = command.mode { params["mode"] = mode }
        // An explicit window wins; otherwise the caller's workspace or surface
        // routes to its own window, like other window-scoped commands.
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: command.window ?? windowOverride)
        let response = try client.sendV2(method: "sidebar.group_by", params: params)
        printV2Payload(
            response,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: response["mode"] as? String ?? ""
        )
    }
}
