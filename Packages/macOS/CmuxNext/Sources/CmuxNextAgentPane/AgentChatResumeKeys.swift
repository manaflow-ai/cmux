public import Foundation

/// The chat-index key (`<index harness>:<harness session id>`, e.g. `claude-code:01a1…`) of each
/// acpmux session an agent tab showed, in a JSON file beside the launch snapshot. When a tab's
/// session is later gone from acpmux ("This chat isn't available"), Resume from Transcript opens
/// that exact chat from its harness transcript (Open Chat), in one step. Only ids are kept,
/// never chat text.
public final class AgentChatResumeKeys {
    public static let fileName = "agent-chat-resume-keys.json"
    /// The newest this many sessions are kept.
    static let capacity = 4_000

    let file: URL?
    private var keys: [String: Entry]
    private var clock = 0

    struct Entry: Codable, Equatable {
        var key: String
        var order: Int
    }

    public init(file: URL?) {
        self.file = file
        // concurrency-allow: one read of a small local state file when the tab store is made
        let data = file.flatMap { try? Data(contentsOf: $0) }
        keys = data.flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        clock = keys.values.map(\.order).max() ?? 0
    }

    /// The file in the tag's state directory (beside the launch snapshot).
    public convenience init(directory: URL?) {
        self.init(file: directory?.appending(path: Self.fileName))
    }

    /// The chat-index key kept for acpmux session `session`, nil when none was.
    public func key(for session: String) -> String? { keys[session]?.key }

    /// Keeps `key` as acpmux session `session`'s chat-index key.
    public func set(_ key: String, for session: String) {
        guard keys[session]?.key != key else { return }
        clock += 1
        keys[session] = Entry(key: key, order: clock)
        if keys.count > Self.capacity {
            let oldest = keys.sorted { $0.value.order < $1.value.order }.prefix(keys.count - Self.capacity).map(\.key)
            for session in oldest { keys[session] = nil }
        }
        save()
    }

    private func save() {
        guard let file else { return }
        // concurrency-allow: one small atomic write when a tab shows a chat it had no key for
        try? JSONEncoder().encode(keys).write(to: file, options: .atomic)
    }
}
