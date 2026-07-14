import CmuxFoundation

actor RecordingPullRequestCommandRunner: CommandRunning {
    private(set) var lastArguments: [String] = []

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        _ = (directory, executable, timeout)
        lastArguments = arguments
        return CommandResult(
            stdout: "",
            stderr: nil,
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
