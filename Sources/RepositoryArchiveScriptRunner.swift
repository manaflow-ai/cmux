import CmuxFoundation

struct RepositoryArchiveScriptRunner: Sendable {
    private let commands: any CommandRunning

    init(commands: any CommandRunning) {
        self.commands = commands
    }

    func run(_ script: String, in directory: String) async -> CommandResult {
        await commands.run(
            directory: directory,
            executable: "/bin/zsh",
            arguments: ["-l", "-c", script],
            timeout: nil
        )
    }
}
