public import CmuxHomeCore
public import CmuxNextDaemon

/// The local Chief owner as ``ChiefWelcome`` sees it: Chief's dots are a local typing event for
/// the Chief participant on Home's source (the owner keeps no typing state), the messages one
/// `conversation-import` on the owner's connection.
public nonisolated struct HomeChiefWelcomeOwner: ChiefWelcomeOwner {
    /// The welcomed Chief conversation.
    public let conversation: ConversationID
    /// Home's local source; the dots are published on it.
    public let source: DaemonHomeSource
    /// The local Chief owner's connection; the import goes over it.
    public let connection: DaemonConnection

    /// - Parameters:
    ///   - conversation: The welcomed Chief conversation.
    ///   - source: Home's local source.
    ///   - connection: The local Chief owner's connection.
    public init(conversation: ConversationID, source: DaemonHomeSource, connection: DaemonConnection) {
        self.conversation = conversation
        self.source = source
        self.connection = connection
    }

    public func showChiefTyping(_ on: Bool) async {
        source.publish(.typing(conversation, ParticipantID(DaemonHomeSource.chief.id), on: on))
    }

    public func importWelcome(_ request: ConversationImportRequest) async throws {
        _ = try await ConversationClient(connection).importHistory(request)
    }
}
