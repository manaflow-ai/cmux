public import CmuxHomeCore
public import CmuxNextSettings
import Foundation

/// The Messages page's staged attachments across launches (`cmux.home.messages.attachments.*`),
/// in HomeStore's draft cache beside the text drafts, as the native composer kept them:
/// - the page's own: each part it uploaded, kept by its hash with its position
///   (``HomeStore/setUploadedDraftAttachment(_:hash:for:)``): a page adds or removes one part, so two
///   pages showing one conversation never overwrite each other's;
/// - the native composer's (``HomeStore/draftAttachments(for:)``, files in the blob cache): handed
///   to the page once, with their bytes, for it to upload into its tray. The page names the ones
///   it took when it saves, and only those leave HomeStore, so none is lost on the way.
@MainActor
public struct HomeMessagesAttachmentDrafts {
    /// The largest native draft file handed to the page, and all of them together (a draft over
    /// either stays in HomeStore, where a later build can still read it).
    public static let maxFileBytes = 25_000_000
    public static let maxTotalBytes = 50_000_000

    private let store: HomeStore

    public init(store: HomeStore) {
        self.store = store
    }

    /// `{attachments: {id: [part]}, legacy: {id: [{hash, name, mimeType, data}]}}`; `data` is base64.
    public func load() async -> JSONValue {
        var own: [String: JSONValue] = [:]
        for id in store.uploadedDraftAttachmentConversations {
            let entries = store.uploadedDraftAttachments(for: id).values.compactMap { try? JSONValue.parse(Data($0.utf8)) }
            let parts = entries.sorted { ($0.value(at: ["at"])?.doubleValue ?? 0) < ($1.value(at: ["at"])?.doubleValue ?? 0) }
                .compactMap { $0.value(at: ["part"]) }
            if !parts.isEmpty { own[id.rawValue] = .array(parts) }
        }
        var legacy: [String: JSONValue] = [:]
        var total = 0
        for id in store.draftAttachmentConversations {
            var files: [JSONValue] = []
            for attachment in store.draftAttachments(for: id) where attachment.ref.byteCount <= Self.maxFileBytes {
                guard total + attachment.ref.byteCount <= Self.maxTotalBytes, let data = await Self.read(attachment.fileURL) else { continue }
                total += data.count
                files.append(.object(["hash": .string(attachment.ref.hash), "name": .string(attachment.ref.name),
                                      "mimeType": .string(attachment.ref.mimeType), "data": .string(data.base64EncodedString())]))
            }
            if !files.isEmpty { legacy[id.rawValue] = .array(files) }
        }
        return .object(["attachments": .object(own), "legacy": .object(legacy)])
    }

    /// Keeps one uploaded part (`at`: its place in the tray) as `id`'s, by its hash.
    public func put(_ part: JSONValue, at: Double, for id: ConversationID) throws {
        guard let hash = part.value(at: ["hash"])?.stringValue, !hash.isEmpty else { throw Refusal.noHash }
        store.setUploadedDraftAttachment(JSONValue.object(["part": part, "at": .number(at)]).compactText, hash: hash, for: id)
    }

    /// Lets go of one uploaded part (sent, or removed from the tray).
    public func remove(_ hash: String, for id: ConversationID) {
        store.setUploadedDraftAttachment(nil, hash: hash, for: id)
    }

    /// Lets go of the native drafts the page took (`migrated`: their hashes).
    public func release(_ migrated: Set<String>, for id: ConversationID) {
        guard !migrated.isEmpty else { return }
        let kept = store.draftAttachments(for: id)
        let left = kept.filter { !migrated.contains($0.ref.hash) }
        if left.count != kept.count { store.setDraftAttachments(left, for: id) }
    }

    public enum Refusal: Error {
        case noHash
    }

    @concurrent nonisolated static func read(_ url: URL) async -> Data? {
        try? Data(blockingContentsOf: url)
    }
}
