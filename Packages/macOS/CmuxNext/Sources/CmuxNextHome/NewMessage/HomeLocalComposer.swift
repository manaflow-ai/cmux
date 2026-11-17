public import CmuxHomeCore
public import CmuxNextDesign

/// Home's message box over a store of its own that knows one local conversation (New Message's
/// blank page): the same composer, glass and send motion as every conversation, text only
/// (attachments upload to a real conversation, which does not exist yet).
@MainActor
public struct HomeLocalComposer: Sendable {
    public let store: HomeStore
    public let view: HomeNativeTranscriptView

    /// Starts the store over `source` and makes the box.
    /// - Parameters:
    ///   - source: The local owner (``HomeNewMessageComposerSource``).
    ///   - conversation: Its one conversation.
    ///   - me: The signed-in person.
    ///   - draft: The text the box starts with.
    ///   - openPanel: The app's made-ahead open panel.
    ///   - spellChecking: The composer's spell checking setting.
    ///   - identifier: The view's accessibility identifier.
    public init(source: any HomeSource, conversation: ConversationID, me: ParticipantID, draft: String,
                openPanel: MadeAheadOpenPanel?, spellChecking: Bool, identifier: String) {
        store = HomeStore(source: source)
        store.start()
        if !draft.isEmpty { store.setDraft(draft, for: conversation) }
        view = HomeNativeTranscriptView(store: store, conversation: conversation, me: me, openPanel: openPanel)
        view.composerSpellCheckingEnabled = spellChecking
        view.attachmentPreparer = nil
        view.setAccessibilityIdentifier(identifier)
    }

    /// Ends the box and its store (connection, resend and prune tasks; the cache flushed).
    public func stop() {
        view.stop()
        store.stop()
    }
}
