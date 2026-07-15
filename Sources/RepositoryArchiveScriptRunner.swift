import CmuxFoundation

struct RepositoryArchiveScriptRunner: Sendable {
    private static let timeout: TimeInterval = 300

    private let commands: any CommandRunning

    init(commands: any CommandRunning) {
        self.commands = commands
    }

    func run(_ script: String, in directory: String) async -> CommandResult {
        let discardedOutputScript = """
        {
        \(script)
        } >/dev/null 2>&1
        """
        await commands.run(
            directory: directory,
            executable: "/bin/zsh",
            arguments: ["-l", "-c", discardedOutputScript],
            timeout: Self.timeout
        )
    }
}
