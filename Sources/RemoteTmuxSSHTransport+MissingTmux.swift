extension RemoteTmuxSSHTransport {
    /// Whether a failed remote command failed because the host has no usable tmux.
    static func indicatesTmuxMissing(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode == 127 else { return false }
        let lowered = stderr.lowercased()
        return lowered.contains(RemoteTmuxHost.tmuxNotFoundSentinel)
            || lowered.contains("exec: tmux: not found")
            || lowered.contains("tmux: command not found")
            || lowered.contains("tmux: not found")
    }

    /// Builds the domain error for a failed remote tmux command.
    nonisolated func commandFailure(_ result: RemoteTmuxCommandResult) -> RemoteTmuxError {
        if Self.indicatesTmuxMissing(exitCode: result.exitCode, stderr: result.stderr) {
            return .tmuxNotFound(destination: host.destination)
        }
        return .commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}
