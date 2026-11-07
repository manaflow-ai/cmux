public import CmuxHomeCore
public import CmuxNextPages
public import CmuxNextSettings

/// What the Messages page keeps in HomeStore across launches, as the native composer kept it, and
/// its files' preparation (the App's `HomeMessagesHostProvider` routes these ops here):
/// - `drafts.load {}` -> `{drafts}`; `drafts.save {conversation, text}`: the composer drafts;
/// - `attachments.load|save`: the staged files (``HomeMessagesAttachmentDrafts``);
/// - `attachments.prepare.*`: a photo's or video's bytes before they upload (``HomeAttachmentPreparer``);
/// - `outbox.load|save`: the unsent sends (``HomeMessagesOutbox``).
@MainActor
public final class HomeMessagesKept {
    /// The longest draft kept (a paste of a log stays a draft; a runaway page cannot fill the cache).
    public static let maxDraftLength = 200_000
    static let preparePrefix = "attachments.prepare."

    private let store: HomeStore
    private let preparer: HomeAttachmentPreparer

    public init(store: HomeStore, keepLocation: @escaping @MainActor () -> Bool) {
        self.store = store
        preparer = HomeAttachmentPreparer(store: store, keepLocation: keepLocation)
    }

    /// Answers `name` (the op after `cmux.home.messages.`), or nil when it is not one of these.
    public func call(_ name: String, _ fields: [String: JSONValue]) async throws -> JSONValue? {
        switch name {
        case "drafts.load":
            let drafts = store.rows.reduce(into: [String: JSONValue]()) { out, row in
                if let text = store.draft(for: row.id), !text.isEmpty { out[row.id.rawValue] = .string(text) }
            }
            return .object(["drafts": .object(drafts)])
        case "drafts.save":
            let text = fields["text"]?.stringValue ?? ""
            guard text.count <= Self.maxDraftLength else { throw PageError.invalidParams("text is longer than a draft keeps") }
            store.setDraft(text, for: try Self.conversation(fields))
            return .null
        case let op where op.hasPrefix(Self.preparePrefix):
            do { return try await preparer.call(String(op.dropFirst(Self.preparePrefix.count)), fields) } catch {
                throw PageError.invalidParams("\(error)")
            }
        case "attachments.load":
            return await HomeMessagesAttachmentDrafts(store: store).load()
        case "attachments.save":
            let migrated = Set((fields["migrated"]?.arrayValue ?? []).compactMap(\.stringValue))
            HomeMessagesAttachmentDrafts(store: store).save(fields["parts"]?.arrayValue ?? [], migrated: migrated, for: try Self.conversation(fields))
            return .null
        case "outbox.load":
            return HomeMessagesOutbox(store: store).load()
        case "outbox.save":
            let id = try Self.conversation(fields)
            do { try HomeMessagesOutbox(store: store).save(fields["pending"]?.arrayValue ?? [], for: id) } catch {
                throw PageError.invalidParams("more unsent sends than the outbox keeps")
            }
            return .null
        default:
            return nil
        }
    }

    static func conversation(_ fields: [String: JSONValue]) throws -> ConversationID {
        guard let id = fields["conversation"]?.stringValue, !id.isEmpty, id.count <= 256 else {
            throw PageError.invalidParams("conversation must be a conversation id")
        }
        return ConversationID(id)
    }
}
