import Foundation

/// New Message's state machine, shared by the iOS sheet and the macOS draft
/// conversation: the To: field draft, the autocomplete suggestions for what
/// is being typed, availability lookups for typed addresses, and the first
/// send that opens (or creates) the conversation.
@MainActor
public final class ConversationComposeSession {
    public enum Change: Sendable, Equatable {
        case recipients
        case suggestions
        case sending
    }

    public let directory: any ConversationDirectory
    public private(set) var draft = ConversationRecipientDraft()
    /// Autocomplete rows for `draft.query`, newest query only.
    public private(set) var suggestions: [ConversationContact] = []
    public private(set) var isSending = false
    public var onChange: (@MainActor (Change) -> Void)?
    public var suggestionLimit = 20

    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    public init(directory: any ConversationDirectory) {
        self.directory = directory
    }

    // MARK: To: field

    public func setText(_ text: String) {
        guard text != draft.text else { return }
        draft.setText(text)
        onChange?(.recipients)
        search()
    }

    /// Picks an autocomplete row (or a contact from the + picker).
    public func add(_ contact: ConversationContact) {
        draft.add(contact)
        clearSuggestions()
        onChange?(.recipients)
    }

    /// Return in the To: field. With suggestions showing, Return takes the
    /// first one, as in Messages; otherwise the typed text becomes a token
    /// and its availability is looked up.
    public func commitText() {
        if !draft.query.isEmpty, let first = suggestions.first {
            add(first)
            return
        }
        guard let recipient = draft.commitText() else { return }
        clearSuggestions()
        onChange?(.recipients)
        guard let handle = recipient.handle else { return }
        Task { [weak self, directory] in
            let lookup: ConversationHandleLookup
            do {
                lookup = try await directory.lookupHandles([handle]).first ?? ConversationHandleLookup(handle: handle, service: nil, contact: nil)
            } catch {
                // A failed lookup leaves the token sendable as text; the server
                // validates again when the conversation is created.
                lookup = ConversationHandleLookup(handle: handle, service: .sms, contact: nil)
            }
            guard let self else { return }
            self.draft.resolve(lookup)
            self.onChange?(.recipients)
        }
    }

    public func select(_ id: String?) {
        draft.select(id)
        onChange?(.recipients)
    }

    public func remove(_ id: String) {
        draft.remove(id)
        onChange?(.recipients)
    }

    /// Backspace; true when a token was selected or deleted.
    @discardableResult
    public func backspace() -> Bool {
        guard draft.backspace() else { return false }
        onChange?(.recipients)
        return true
    }

    // MARK: Autocomplete

    private func clearSuggestions() {
        searchTask?.cancel()
        searchGeneration += 1
        guard !suggestions.isEmpty else { return }
        suggestions = []
        onChange?(.suggestions)
    }

    private func search() {
        let query = draft.query
        guard !query.isEmpty else {
            clearSuggestions()
            return
        }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let excluding = draft.contactIDs
        let limit = suggestionLimit
        searchTask = Task { [weak self, directory] in
            let found = (try? await directory.searchContacts(query, limit: limit, excluding: excluding)) ?? []
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            self.suggestions = found
            self.onChange?(.suggestions)
        }
    }

    // MARK: First send

    /// Resolves the recipients to a conversation. Typed text left in the To:
    /// field counts as a recipient, as in Messages.
    public func openConversation() async throws -> ConversationCreation {
        if !draft.query.isEmpty { commitText() }
        guard !draft.recipients.isEmpty else {
            throw ConversationBackendError(code: -32602, message: "no recipients")
        }
        if draft.recipients.contains(where: { $0.state == .invalid }) {
            throw ConversationBackendError(code: -32005, message: "not a valid address")
        }
        isSending = true
        onChange?(.sending)
        defer {
            isSending = false
            onChange?(.sending)
        }
        return try await directory.createConversation(draft.recipients.map(\.ref))
    }
}

/// An image in New Message's first message (or a forwarded draft).
public struct ConversationComposeImage: Sendable, Hashable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var mimeType: String

    public init(data: Data, width: Int, height: Int, mimeType: String) {
        self.data = data
        self.width = width
        self.height = height
        self.mimeType = mimeType
    }
}

/// The first message New Message sends into the conversation it opens.
public struct ConversationComposeMessage: Sendable, Hashable {
    public var text: String
    public var images: [ConversationComposeImage]

    public init(text: String, images: [ConversationComposeImage] = []) {
        self.text = text
        self.images = images
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }
}

extension ConversationStore {
    /// Sends `message` as soon as the session is connected: the first message
    /// of a conversation New Message just opened.
    public func sendWhenConnected(_ message: ConversationComposeMessage) {
        let images = message.images.map { (data: $0.data, width: $0.width, height: $0.height, mimeType: $0.mimeType) }
        if meID != nil {
            send(text: message.text, images: images)
            return
        }
        var sent = false
        addObserver { [weak self] change in
            guard !sent, change == .connection, let self, self.meID != nil else { return }
            sent = true
            self.send(text: message.text, images: images)
        }
    }
}
