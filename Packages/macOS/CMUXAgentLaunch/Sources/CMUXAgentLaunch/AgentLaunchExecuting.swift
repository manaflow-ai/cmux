import Foundation

/// Performs the terminal mutations selected by ``AgentLaunchGuard``.
@MainActor
public protocol AgentLaunchExecuting: AnyObject {
    /// Clears terminal input residue, types `command`, and submits it once.
    ///
    /// - Parameters:
    ///   - surfaceID: The stable terminal surface identifier.
    ///   - command: The complete agent launch shell command.
    /// - Returns: Whether the full input sequence was accepted.
    func typeLaunchCommand(surfaceID: String, command: String) -> AgentLaunchExecutionResult

    /// Clears the agent composer, types `text`, and submits it once.
    ///
    /// - Parameters:
    ///   - surfaceID: The stable terminal surface identifier.
    ///   - text: The prompt to submit.
    ///   - ticketID: A client-minted idempotency identifier, when available.
    /// - Returns: Whether the full input sequence was accepted or phase-gated into a queue.
    func submitPrompt(surfaceID: String, text: String, ticketID: UUID?) -> AgentLaunchExecutionResult
}
