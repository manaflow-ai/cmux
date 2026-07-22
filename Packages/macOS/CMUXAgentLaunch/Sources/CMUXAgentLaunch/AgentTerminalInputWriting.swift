/// Writes explicit text and named keys to one terminal input queue.
@MainActor
public protocol AgentTerminalInputWriting: AnyObject {
    /// Sends a named key such as `ctrl+a` or `return`.
    func sendNamedKey(_ keyName: String) -> AgentLaunchExecutionResult

    /// Sends text as one bracketed-paste-compatible input block.
    func sendText(_ text: String) -> AgentLaunchExecutionResult
}
