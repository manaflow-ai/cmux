import ArgumentParser
import Foundation

struct CmuxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cmux",
        abstract: String(
            localized: "cli.root.abstract",
            defaultValue: "Control cmux via Unix socket."
        ),
        subcommands: [DumpCommandTree.self]
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
