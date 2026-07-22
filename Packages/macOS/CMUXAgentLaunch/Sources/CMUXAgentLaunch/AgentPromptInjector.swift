/// Clears terminal composer residue before typing and submitting one text block.
public struct AgentPromptInjector: Sendable {
    /// Creates a stateless prompt injector.
    public init() {}

    /// Clears the current input line, types `text`, and sends exactly one submit key.
    ///
    /// - Parameters:
    ///   - text: The prompt or launch command to type.
    ///   - submitKey: The agent-aware named key used to submit the text.
    ///   - writer: The terminal input seam.
    /// - Returns: The first failure, or whether any operation was queued.
    @MainActor
    public func submit(
        text: String,
        submitKey: String,
        writer: any AgentTerminalInputWriting
    ) -> AgentLaunchExecutionResult {
        var queued = false
        for keyName in ["ctrl+a", "ctrl+k", "ctrl+u"] {
            switch writer.sendNamedKey(keyName) {
            case .accepted:
                break
            case .queued:
                queued = true
            case .failed(let code):
                return .failed(code)
            }
        }
        switch writer.sendText(text) {
        case .accepted:
            break
        case .queued:
            queued = true
        case .failed(let code):
            return .failed(code)
        }
        switch writer.sendNamedKey(submitKey) {
        case .accepted:
            break
        case .queued:
            queued = true
        case .failed(let code):
            return .failed(code)
        }
        return queued ? .queued : .accepted
    }
}
