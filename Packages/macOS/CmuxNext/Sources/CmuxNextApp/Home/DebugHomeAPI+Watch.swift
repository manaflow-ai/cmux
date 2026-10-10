import CmuxHomeCore
import CmuxNextSettings
import Foundation

/// `debug.home.api` `watch_start` / `watch_read` / `store`: a second front
/// end on the one data path. `watch_start` subscribes its own
/// `homeRouter.events()` stream (as the React Home's provider does) next to
/// the Swift Home's `HomeStore`; `watch_read` returns the message events it
/// got; `store` returns the Swift Home store's transcript of a conversation.
/// A write in either Home must show in both.
@MainActor
enum DebugHomeWatch {
    private static var task: Task<Void, Never>?
    private static var seen: [JSONValue] = []
    private static let capacity = 2_000

    static func start(_ router: HomeSourceRouter) -> JSONValue {
        task?.cancel()
        seen.removeAll()
        // task-owner: the debug watch; replaced by the next watch_start
        task = Task { @MainActor in
            for await event in await router.events() {
                guard case .message(let message, let rev) = event, seen.count < capacity else { continue }
                var row = DebugHomeAPI.message(message)
                if case .object(var fields) = row {
                    fields["conversation"] = .string(message.conversation.rawValue)
                    fields["rev"] = JSONValue(Int(rev))
                    row = .object(fields)
                }
                seen.append(row)
            }
        }
        return .object(["ok": .bool(true)])
    }

    static func read() -> JSONValue { .object(["ok": .bool(task != nil), "events": .array(seen)]) }

    static func store(_ store: HomeStore, conversation: ConversationID) -> JSONValue {
        let items = store.transcript(for: conversation).map { item -> JSONValue in
            .object(["id": item.messageID.map { .string($0.rawValue) } ?? .null, "text": .string(item.plainText),
                     "edited": .bool(item.editedAt != nil), "retracted": .bool(item.isRetracted),
                     "reactions": JSONValue(item.reactions.count),
                     "thread_root": item.threadRoot.map { .string($0.rawValue) } ?? .null])
        }
        return .object(["ok": .bool(true), "items": .array(items)])
    }
}
