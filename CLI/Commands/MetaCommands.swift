import ArgumentParser
import Foundation

/// Routes a facade declaration back through the established CLI implementation.
private protocol LegacyFacadeCommand: ParsableCommand {}

extension LegacyFacadeCommand {
    func run() throws {
        try GlobalOptions().makeCLI().run()
    }
}

private protocol LegacyMetaCommand: LegacyFacadeCommand {}

struct WelcomeCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "welcome", helpNames: [])
}

struct DocsCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "docs", helpNames: [])
}

struct SettingsCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "settings", helpNames: [])
}

struct ConfigCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
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
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []
    static let configuration = CommandConfiguration(commandName: "feedback", helpNames: [])
}

struct ThemesCommand: LegacyMetaCommand {
    @Argument(parsing: .allUnrecognized) var arguments: [String] = []

    static let configuration = CommandConfiguration(
        commandName: "themes",
        subcommands: [ThemesListCommand.self, ThemesSetCommand.self, ThemesClearCommand.self],
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
