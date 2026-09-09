import ArgumentParser
import Foundation

/// Routes a facade declaration back through the established CLI implementation.
private protocol LegacyFacadeCommand: SharedLegacyFacadeCommand {}

private protocol LegacyMetaCommand: LegacyFacadeCommand {}

struct WelcomeCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "welcome", helpNames: [])
}

struct DocsCommand: LegacyMetaCommand {
    // A single topic, not a subcommand tree: the runner rejects more than one
    // argument, so `.allUnrecognized` keeps the shape while the completion kind
    // supplies the topics.
    @Argument(parsing: .allUnrecognized, completion: .list(CMUXCLI.docsTopicNames))
    var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "docs", helpNames: [])
}

struct SettingsCommand: LegacyMetaCommand {
    // `open`, `path`, and `docs` are subcommands; every other value is a target
    // section, and `open <target>` accepts the targets too. One flat candidate
    // list covers both positions without splitting the runner's dispatch.
    @Argument(
        parsing: .allUnrecognized,
        completion: .list(["open", "path", "docs"] + CMUXCLI.settingsTargetNames)
    ) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "settings", helpNames: [])
}

struct ConfigCommand: LegacyMetaCommand {
    @Option(name: .customLong("path"), completion: .file()) var path: String?
    // The two font-size keys are both subcommands and the values `get`/`set`
    // take, so one list covers every position; the runner validates which
    // combination is legal.
    @Argument(parsing: .allUnrecognized, completion: .list(CMUXCLI.configSubcommandNames))
    var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "config", helpNames: [])
}

struct ShortcutsCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "shortcuts", helpNames: [])
}

struct VersionCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    // The legacy parser deliberately prints the version summary for --help.
    static let configuration = CommandConfiguration(commandName: "version", helpNames: [])
}

struct CapabilitiesCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "capabilities", helpNames: [])
}

struct PingCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "ping", helpNames: [])
}

struct IrohDiagnosticsCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "iroh-diag", helpNames: [])
}

struct HelpCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "help", helpNames: [])
}

struct ReloadConfigCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "reload-config", helpNames: [])
}

struct FeedbackCommand: LegacyMetaCommand {
    @Option(name: .customLong("email")) var email: String?
    @Option(name: .customLong("body")) var body: String?
    // `--image` repeats; the array default `.singleValue` already reads exactly
    // one value per occurrence, matching the legacy `parseRepeatedOption`.
    @Option(name: .customLong("image"), completion: .file()) var images: [String] = []
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "feedback", helpNames: [])
}

struct ThemesCommand: LegacyMetaCommand {
    // No catch-all argument here: ArgumentParser already generates a rest-argument
    // spec to dispatch into `subcommands`, and a second one on this struct produces
    // an invalid duplicate `_arguments` spec in the generated zsh completion script.
    // `defaultSubcommand` absorbs anything that doesn't name a declared subcommand.
    static let configuration = CommandConfiguration(
        commandName: "themes",
        subcommands: [ThemesListCommand.self, ThemesSetCommand.self, ThemesClearCommand.self],
        defaultSubcommand: ThemesListCommand.self,
        helpNames: []
    )
}

struct ThemesListCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "list", helpNames: [])
}

struct ThemesSetCommand: LegacyMetaCommand {
    @Option(name: .customLong("light"), completion: .custom(CompletionCandidates.themes))
    var light: String?

    @Option(name: .customLong("dark"), completion: .custom(CompletionCandidates.themes))
    var dark: String?

    @Argument(parsing: .allUnrecognized, completion: .custom(CompletionCandidates.themes))
    var themes: [String] = []

    static let configuration = CommandConfiguration(commandName: "set", helpNames: [])
}

struct ThemesClearCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "clear", helpNames: [])
}

struct InternalFlagsCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "__internal_flags", shouldDisplay: false, helpNames: [])
}

struct SidebarFooterIconBalanceCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "__sidebar_footer_icon_balance", shouldDisplay: false, helpNames: [])
}
