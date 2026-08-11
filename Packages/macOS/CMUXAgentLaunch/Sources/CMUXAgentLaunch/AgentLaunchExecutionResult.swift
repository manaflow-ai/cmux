/// The result of writing an agent launch command or prompt to a terminal surface.
public enum AgentLaunchExecutionResult: Equatable, Sendable {
    /// The complete input sequence was accepted immediately.
    case accepted
    /// The complete input sequence was accepted by the terminal input queue.
    case queued
    /// The input sequence was rejected with a stable diagnostic code.
    case failed(String)
}
