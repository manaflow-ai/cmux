extension CMUXCLI {
    /// Emits the structured success acknowledgement for Claude Code hooks.
    ///
    /// Claude Code consumes a bare JSON object without rendering a visible
    /// hook-success block. The process exit code remains the success signal.
    func printClaudeHookAck() {
        print("{}")
    }
}
