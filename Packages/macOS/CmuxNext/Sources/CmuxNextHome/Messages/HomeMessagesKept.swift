public import CmuxHomeCore
public import CmuxHomeRender
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// What the Messages page keeps in HomeStore across launches, as the native composer kept it, and
/// its files' preparation (the App's `HomeMessagesHostProvider` routes these ops here):
/// - `drafts.load {}` -> `{drafts}`; `drafts.save {conversation, text}`: the composer drafts;
/// - `attachments.load|put|remove|release`: the staged files, one part each, and `attachments.write|read`
///   their bytes (``HomeMessagesAttachmentDrafts``);
/// - `attachments.prepare.*`: a photo's or video's bytes before they upload (``HomeAttachmentPreparer``);
/// - `outbox.load|put|remove`: the unsent sends, one send each (``HomeMessagesOutbox``);
/// - `approval.decide`: a Chief's permission card, on the person's click (``HomeMessagesApprovals``);
/// - `composing {conversation, typing}`: my typing indicator, through HomeStore's own throttled
///   start and stop (``HomeStore/composing(_:in:)``, as the native composer reported it).
@MainActor
public final class HomeMessagesKept {
    /// The longest draft kept (a paste of a log stays a draft; a runaway page cannot fill the cache).
    public static let maxDraftLength = 200_000
    static let preparePrefix = "attachments.prepare."
    /// A send too large to keep (``HomeMessagesOutbox/maxEntryBytes``): the page says it is not kept.
    public static let tooLargeCode = "cmux.home.outbox.too_large"

    private let store: HomeStore
    private let preparer: HomeAttachmentPreparer
    private let approvals: HomeMessagesApprovals

    /// `approvals` answers acpmux for a permission card (the App's `ChiefApprovalDecider`; nil refuses each click).
    public init(store: HomeStore, keepLocation: @escaping @MainActor () -> Bool, approvals: (any HomeApprovalDeciding)? = nil) {
        self.store = store
        preparer = HomeAttachmentPreparer(store: store, keepLocation: keepLocation)
        self.approvals = HomeMessagesApprovals(store: store, decider: approvals)
    }

    /// Answers `name` (the op after `cmux.home.messages.`), or nil when it is not one of these.
    public func call(_ name: String, _ fields: [String: JSONValue], context: PageCallContext? = nil) async throws -> JSONValue? {
        if name == HomeMessagesApprovals.op {
            return try await approvals.call(name, fields, context: context ?? PageCallContext(page: ""))
        }
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
        case "attachments.put":
            let id = try Self.conversation(fields)
            do { try HomeMessagesAttachmentDrafts(store: store).put(fields["part"] ?? .null, at: fields["at"]?.doubleValue ?? 0, for: id) } catch {
                throw PageError.invalidParams("part must name its hash")
            }
            return .null
        case "attachments.remove":
            let drafts = HomeMessagesAttachmentDrafts(store: store)
            let hash = fields["hash"]?.stringValue ?? ""
            drafts.remove(hash, for: try Self.conversation(fields))
            await drafts.releaseBytes(hash)
            return .null
        case "attachments.write":
            guard let hash = fields["hash"]?.stringValue, let offset = Self.count(fields["offset"]),
                  let count = Self.count(fields["byteCount"]),
                  let data = fields["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
                throw PageError.invalidParams("write needs hash, offset, byteCount and data")
            }
            do { try await HomeMessagesAttachmentDrafts(store: store).write(hash: hash, offset: offset, data: data, byteCount: count) } catch {
                throw PageError.invalidParams("\(error)")
            }
            return .null
        case "attachments.read":
            guard let hash = fields["hash"]?.stringValue, let offset = Self.count(fields["offset"]),
                  let length = Self.count(fields["length"]) else { throw PageError.invalidParams("read needs hash, offset and length") }
            do {
                let data = try await HomeMessagesAttachmentDrafts(store: store).read(hash: hash, offset: offset, length: length)
                return .object(["data": .string(data.base64EncodedString())])
            } catch {
                throw PageError.invalidParams("\(error)")
            }
        case "attachments.release":
            let migrated = Set((fields["migrated"]?.arrayValue ?? []).compactMap(\.stringValue))
            HomeMessagesAttachmentDrafts(store: store).release(migrated, for: try Self.conversation(fields))
            return .null
        case "composing":
            let id = try Self.conversation(fields)
            // HomeStore throttles it: an `on` at most every refresh interval, an `off` after its idle
            // time, when the field empties or the conversation closes.
            if fields["typing"]?.boolValue == true { store.composing("typing", in: id) } else { store.stopTyping(in: id) }
            return .null
        case "outbox.load":
            return HomeMessagesOutbox(store: store).load()
        case "outbox.put":
            let id = try Self.conversation(fields)
            do { try HomeMessagesOutbox(store: store).put(fields["send"] ?? .null, for: id) } catch HomeMessagesOutbox.Refusal.tooLarge {
                throw PageError(code: Self.tooLargeCode, message: "the send is larger than the outbox keeps")
            } catch {
                throw PageError.invalidParams("send must carry its key")
            }
            return .null
        case "outbox.remove":
            // The send's files' bytes go with it, unless a tray or another send still names them.
            let hashes = HomeMessagesOutbox(store: store).remove(fields["key"]?.stringValue ?? "", for: try Self.conversation(fields))
            let drafts = HomeMessagesAttachmentDrafts(store: store)
            for hash in Set(hashes) { await drafts.releaseBytes(hash) }
            return .null
        default:
            return nil
        }
    }

    /// A whole byte count or offset the page sent (nil for anything else, so no conversion traps).
    static func count(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number >= 0, number <= 1e12, number.rounded() == number else { return nil }
        return Int(number)
    }

    /// The `conversation` field's id; refused when it is not one.
    public static func conversation(_ fields: [String: JSONValue]) throws -> ConversationID {
        guard let id = fields["conversation"]?.stringValue, !id.isEmpty, id.count <= 256 else {
            throw PageError.invalidParams("conversation must be a conversation id")
        }
        return ConversationID(id)
    }
}
