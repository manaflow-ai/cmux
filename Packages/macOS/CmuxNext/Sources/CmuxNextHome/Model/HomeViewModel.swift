public import Foundation
public import Observation

/// The Home surface's input: conversation rows, the selection and the open
/// transcript. The App fills it from the conversation mirror; the views
/// observe it and send intents through `actions`.
@Observable
@MainActor
public final class HomeViewModel {
    public var conversations: [HomeConversationSummary]
    public var selectedConversationID: String?
    /// The selected conversation's transcript (nil while none is open).
    public var transcript: (any HomeTranscriptSource)?
    /// Who is typing in the open conversation (the transcript view keeps it current).
    public var typingParticipantIDs: [String] = []
    @ObservationIgnored public weak var actions: (any HomeActions)?

    public init(conversations: [HomeConversationSummary] = [], selectedConversationID: String? = nil,
                transcript: (any HomeTranscriptSource)? = nil, actions: (any HomeActions)? = nil) {
        self.conversations = conversations
        self.selectedConversationID = selectedConversationID
        self.transcript = transcript
        self.actions = actions
    }

    public var selectedConversation: HomeConversationSummary? {
        conversations.first { $0.id == selectedConversationID }
    }
}
