import ArgumentParser
import Foundation

struct CmuxCommand: ParsableCommand {
    @OptionGroup var globals: GlobalOptions

    static let configuration = CommandConfiguration(
        commandName: "cmux",
        abstract: String(
            localized: "cli.root.abstract",
            defaultValue: "Control cmux via Unix socket."
        ),
        subcommands: [
            CompleteCandidates.self,
            Completion.self,
            DumpCommandTree.self,
            WelcomeCommand.self,
            DocsCommand.self,
            SettingsCommand.self,
            ConfigCommand.self,
            ShortcutsCommand.self,
            VersionCommand.self,
            CapabilitiesCommand.self,
            PingCommand.self,
            IrohDiagnosticsCommand.self,
            HelpCommand.self,
            ReloadConfigCommand.self,
            FeedbackCommand.self,
            ThemesCommand.self,
            InternalFlagsCommand.self,
            SidebarFooterIconBalanceCommand.self,
            AuthCommand.self,
            AIAccountsCommand.self,
        ]
    )

    /// Every command name and alias the facade owns. The router sends only these
    /// to ArgumentParser; everything else falls through to the legacy parser.
    static var declaredCommandNames: Set<String> {
        var names: Set<String> = []
        for subcommand in configuration.subcommands {
            let config = subcommand.configuration
            if let name = config.commandName { names.insert(name) }
            names.formUnion(config.aliases)
        }
        return names
    }
}
