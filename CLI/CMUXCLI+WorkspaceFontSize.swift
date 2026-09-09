import Foundation

extension CMUXCLI {
    static let workspaceFontSizeCommandUsage = String(localized: "cli.workspaceFontSize.usage", defaultValue: """
    Usage: cmux workspace-font-size <increase|decrease|reset> [--workspace <id|ref|index>] [--window <id|ref|index>] [--json]

    Request the same font-size action as the GUI for all terminal panels in the
    target workspace. Increase and decrease use a relative 1pt step; reset
    restores the configured size. The command does not change focus. Human
    output confirms that the request was accepted; queued work may defer it.
    """)

    private enum WorkspaceFontSizeAction: String {
        case increase
        case decrease
        case reset
    }

    private struct WorkspaceFontSizeArguments {
        let action: WorkspaceFontSizeAction
        let workspace: String?
        let window: String?
    }

    func runWorkspaceFontSizeCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.workspaceFontSizeCommandUsage)
            return
        }

        let parsed = try parseWorkspaceFontSizeArguments(commandArgs)
        let windowID = try normalizeWindowHandle(parsed.window ?? windowOverride, client: client)
        let workspaceRaw = parsed.workspace
            ?? (windowID == nil ? ProcessInfo.processInfo.environment["CMUX_WORKSPACE_ID"] : nil)
        let workspaceID = try normalizeWorkspaceHandle(
            workspaceRaw,
            client: client,
            windowHandle: windowID
        )

        var params: [String: Any] = ["action": parsed.action.rawValue]
        if let workspaceID { params["workspace_id"] = workspaceID }
        if let windowID { params["window_id"] = windowID }

        let payload = try client.sendV2(method: "workspace.font_size", params: params)
        let accepted = String(
            localized: "cli.workspaceFontSize.accepted",
            defaultValue: "Workspace font size request accepted: \(parsed.action.rawValue). Application may be deferred."
        )
        printV2Payload(
            payload,
            jsonOutput: jsonOutput,
            idFormat: idFormat,
            fallbackText: accepted
        )
    }

    private func parseWorkspaceFontSizeArguments(_ args: [String]) throws -> WorkspaceFontSizeArguments {
        guard let first = args.first, !first.hasPrefix("-") else {
            throw CLIError(message: String(
                localized: "cli.workspaceFontSize.error.missingAction",
                defaultValue: "workspace-font-size requires increase, decrease, or reset"
            ))
        }
        guard let action = WorkspaceFontSizeAction(rawValue: first.lowercased()) else {
            throw CLIError(message: String(
                localized: "cli.workspaceFontSize.error.invalidAction",
                defaultValue: "Invalid workspace font-size action '\(first)'; expected increase, decrease, or reset"
            ))
        }

        var workspace: String?
        var window: String?
        var index = 1
        var pastSeparator = false
        while index < args.count {
            let arg = args[index]
            if pastSeparator {
                throw unknownWorkspaceFontSizeArgument(arg)
            }
            if arg == "--" {
                pastSeparator = true
                index += 1
                continue
            }
            if arg == "--json" {
                index += 1
                continue
            }

            let option: String
            let inlineValue: String?
            if let equals = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                option = String(arg[..<equals])
                inlineValue = String(arg[arg.index(after: equals)...])
            } else {
                option = arg
                inlineValue = nil
            }
            guard option == "--workspace" || option == "--window" else {
                throw unknownWorkspaceFontSizeArgument(arg)
            }

            let value: String
            if let inlineValue {
                value = inlineValue
            } else {
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else {
                    throw CLIError(message: String(
                        localized: "cli.workspaceFontSize.error.optionValue",
                        defaultValue: "\(option) requires a workspace or window id, ref, or index"
                    ))
                }
                value = args[index + 1]
                index += 1
            }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.workspaceFontSize.error.optionValue",
                    defaultValue: "\(option) requires a workspace or window id, ref, or index"
                ))
            }

            if option == "--workspace" {
                guard workspace == nil else {
                    throw duplicateWorkspaceFontSizeArgument(option)
                }
                workspace = value
            } else {
                guard window == nil else {
                    throw duplicateWorkspaceFontSizeArgument(option)
                }
                window = value
            }
            index += 1
        }
        return WorkspaceFontSizeArguments(action: action, workspace: workspace, window: window)
    }

    private func unknownWorkspaceFontSizeArgument(_ argument: String) -> CLIError {
        CLIError(message: String(
            localized: "cli.workspaceFontSize.error.unknownArgument",
            defaultValue: "Unknown workspace-font-size argument: \(argument)"
        ))
    }

    private func duplicateWorkspaceFontSizeArgument(_ option: String) -> CLIError {
        CLIError(message: String(
            localized: "cli.workspaceFontSize.error.duplicateArgument",
            defaultValue: "Duplicate workspace-font-size argument: \(option)"
        ))
    }
}
