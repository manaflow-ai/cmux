public import CmuxHomeCore

/// The model behind a Chief: runs one turn and streams what it does.
///
/// Implementations drive an agent CLI (Claude Code, Codex) or, in tests, a
/// script. ``ChiefConversationOwner`` runs at most one turn per conversation
/// and consumes the stream on one task. To stop a turn the owner cancels that
/// task, which terminates the stream; a driver terminates its process from the
/// stream's `onTermination`.
///
/// A driver may keep one long-lived CLI process per conversation; `run` is
/// called once per user turn. A message the user sends while a turn runs is
/// queued by the owner and becomes the next `run`.
///
/// Stopping a turn: the owner calls ``interrupt(conversation:)``, then
/// cancels the consuming task.
///
/// ```swift
/// struct EchoBrain: ChiefBrain {
///     func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
///         AsyncThrowingStream { continuation in
///             continuation.yield(.textDelta(request.userText))
///             continuation.yield(.textSegmentEnd)
///             continuation.yield(.finished)
///             continuation.finish()
///         }
///     }
///     func respond(toApproval id: String, choice: String, conversation: ConversationID) async {}
///     func interrupt(conversation: ConversationID) async {}
///     func shutdown() async {}
/// }
/// ```
public protocol ChiefBrain: Sendable {
    /// Starts one turn.
    ///
    /// - Parameter request: The user's text, attachments and the turn's context.
    /// - Returns: The turn's events, ending with ``ChiefTurnEvent/finished`` or
    ///   ``ChiefTurnEvent/failed(_:)``. A stream that ends without either counts
    ///   as finished; a thrown error counts as failed.
    func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error>

    /// Delivers the user's answer to an approval the turn requested with
    /// ``ChiefTurnEvent/approvalRequested(id:prompt:options:)``.
    ///
    /// - Parameters:
    ///   - id: The approval's id from the event.
    ///   - choice: One of the event's options.
    ///   - conversation: The conversation whose turn asked.
    func respond(toApproval id: String, choice: String, conversation: ConversationID) async

    /// Interrupts the running turn of `conversation` (the user pressed Stop).
    /// The owner cancels the consuming task right after.
    ///
    /// - Parameter conversation: The conversation whose turn stops.
    func interrupt(conversation: ConversationID) async

    /// Stops every process the brain keeps (app quit, owner shutdown).
    func shutdown() async
}
