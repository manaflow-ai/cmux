import ArgumentParser
import Foundation

extension CMUXCLI {
    struct CommandFormArguments: ParsableArguments {
        @Argument var command: TopLevelCommandName

        @Argument(parsing: .allUnrecognized)
        var tail: [String] = []
    }

    static func verifyArgumentParserCommandForm(_ form: String) throws {
        let tokens = form.split(separator: " ").map(String.init)
        let parsed: CommandFormArguments
        do {
            parsed = try CommandFormArguments.parse(tokens)
        } catch {
            throw CLIError(message: "ArgumentParser command form failed for '\(form)': \(String(describing: error))")
        }

        do {
            try verifyCommandTail(command: parsed.command, tail: parsed.tail)
        } catch {
            throw CLIError(message: "ArgumentParser command tail failed for '\(form)': \(error)")
        }
    }

    static func verifyCommandTail(command: TopLevelCommandName, tail: [String]) throws {
        switch command {
        case .auth:
            try verifyOptionalTailCommand(AuthSubcommandName.self, tail: tail)
        case .feed:
            try verifyOptionalTailCommand(FeedSubcommandName.self, tail: tail)
        case .docs:
            try verifyOptionalTailCommand(DocsSubcommandName.self, tail: tail)
        case .settings:
            try verifyOptionalTailCommand(SettingsSubcommandName.self, tail: tail)
        case .hooks:
            try verifyHooksTail(tail)
        case .themes:
            try verifyOptionalTailCommand(ThemeSubcommandName.self, tail: tail)
        case .codex:
            try verifyOptionalTailCommand(AgentInstallerSubcommandName.self, tail: tail)
        case .vm, .cloud:
            try verifyOptionalTailCommand(VMSubcommandName.self, tail: tail)
        case .browser:
            try verifyBrowserTail(tail)
        case .markdown:
            try verifyOptionalTailCommand(MarkdownSubcommandName.self, tail: tail)
        case .tmuxCompat:
            try verifyOptionalTailCommand(TmuxShimCommandName.self, tail: tail, allowDashCommand: true)
        case .claudeHook:
            try verifyOptionalTailCommand(ClaudeHookSubcommandName.self, tail: tail)
        default:
            break
        }
    }

    static func verifyOptionalTailCommand<Command: CLICommandName>(
        _ type: Command.Type,
        tail: [String],
        allowDashCommand: Bool = false
    ) throws {
        guard let first = tail.first else { return }
        if first.hasPrefix("-"), !allowDashCommand { return }
        _ = try parseCommandName(type, raw: first)
    }

    static func verifyBrowserTail(_ tail: [String]) throws {
        guard let first = tail.first else { return }
        if first.hasPrefix("-") { return }
        let subcommand = try parseCommandName(BrowserSubcommandName.self, raw: first)
        let nested = Array(tail.dropFirst())

        switch subcommand {
        case .get:
            try verifyOptionalTailCommand(BrowserGetSubcommandName.self, tail: nested)
        case .isCommand:
            try verifyOptionalTailCommand(BrowserIsSubcommandName.self, tail: nested)
        case .find:
            try verifyOptionalTailCommand(BrowserFindSubcommandName.self, tail: nested)
        case .frame:
            try verifyOptionalTailCommand(BrowserFrameSubcommandName.self, tail: nested)
        case .dialog:
            try verifyOptionalTailCommand(BrowserDialogSubcommandName.self, tail: nested)
        case .download:
            try verifyOptionalTailCommand(BrowserDownloadSubcommandName.self, tail: nested)
        case .cookies:
            try verifyOptionalTailCommand(BrowserCookiesSubcommandName.self, tail: nested)
        case .storage:
            guard let storageType = nested.first else { return }
            _ = try parseCommandName(BrowserStorageTypeName.self, raw: storageType)
            try verifyOptionalTailCommand(BrowserStorageOperationName.self, tail: Array(nested.dropFirst()))
        case .tab:
            try verifyOptionalTailCommand(BrowserTabSubcommandName.self, tail: nested)
        case .console, .errors:
            try verifyOptionalTailCommand(BrowserLogSubcommandName.self, tail: nested)
        case .state:
            try verifyOptionalTailCommand(BrowserStateSubcommandName.self, tail: nested)
        case .trace:
            try verifyOptionalTailCommand(BrowserTraceSubcommandName.self, tail: nested)
        case .network:
            try verifyOptionalTailCommand(BrowserNetworkSubcommandName.self, tail: nested)
        case .screencast:
            try verifyOptionalTailCommand(BrowserScreencastSubcommandName.self, tail: nested)
        case .input:
            try verifyOptionalTailCommand(BrowserInputSubcommandName.self, tail: nested)
        default:
            break
        }
    }

    static func verifyHooksTail(_ tail: [String]) throws {
        guard let first = tail.first else { return }
        if first.hasPrefix("-") { return }

        let target = try parseCommandName(HooksTargetName.self, raw: first)
        let nested = Array(tail.dropFirst())

        switch target {
        case .setup, .uninstall, .feed:
            return
        case .claude:
            try verifyOptionalTailCommand(ClaudeHookSubcommandName.self, tail: nested)
        case .codex, .opencode, .cursor, .gemini, .copilot, .codebuddy, .factory, .qoder:
            guard let action = nested.first else { return }
            if action == "install" || action == "uninstall" {
                _ = try parseCommandName(HooksAgentActionName.self, raw: action)
                return
            }
            try verifyOptionalTailCommand(GenericAgentHookSubcommandName.self, tail: nested)
        }
    }
}
