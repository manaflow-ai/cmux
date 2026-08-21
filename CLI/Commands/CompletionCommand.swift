import ArgumentParser
import Foundation

struct Completion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: String(
            localized: "cli.command.completion.abstract",
            defaultValue: "Print a shell completion script for cmux."
        ),
        discussion: String(
            localized: "cli.command.completion.discussion",
            defaultValue: """
            Add the matching line to your shell startup file:
              zsh:  eval "$(cmux completion zsh)"
              bash: eval "$(cmux completion bash)"
              fish: cmux completion fish | source
            """
        )
    )

    @Argument(
        help: String(
            localized: "cli.command.completion.shell.help",
            defaultValue: "Shell to generate a script for."
        ),
        completion: .list(["bash", "zsh", "fish"])
    )
    var shell: String

    func run() throws {
        guard let kind = CompletionShell(rawValue: shell) else {
            throw CLIError(
                message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.command.completion.unsupportedShell",
                        defaultValue: "Unsupported shell '%@'. Supported: bash, zsh, fish."
                    ),
                    shell
                ),
                exitCode: 2
            )
        }
        print(CmuxCommand.completionScript(for: kind))
    }
}
