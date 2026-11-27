public import CmuxNextDaemon

/// What ``ChiefWelcome`` needs from the Chief's conversation owner: Chief's typing dots on the
/// person's screen and the one import that stores the welcome as Chief's own messages.
///
/// The app conforms with the local Chief owner (`HomeService`): the dots are a local typing event
/// for the Chief participant, the messages go through `conversation-import`. Tests pass a fake
/// that records the calls.
public nonisolated protocol ChiefWelcomeOwner: Sendable {
    /// Shows (`true`) or removes (`false`) Chief's typing dots in the welcomed conversation.
    /// - Parameter on: Whether the dots show.
    func showChiefTyping(_ on: Bool) async

    /// Stores the welcome messages in the conversation, as Chief's.
    /// - Parameter request: The import ``ChiefWelcome/request(now:)`` built.
    /// - Throws: The owner's error; nothing was stored.
    func importWelcome(_ request: ConversationImportRequest) async throws
}
