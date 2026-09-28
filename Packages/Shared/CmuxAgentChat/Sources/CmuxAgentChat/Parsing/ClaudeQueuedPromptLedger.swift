import Foundation

/// Tracks the prompts waiting in Claude Code's input queue from its session
/// transcript's `queue-operation` lines.
///
/// Claude Code writes `enqueue` (with the prompt) when you send while a turn
/// runs, then exactly one of `dequeue` (sent as the next turn), `remove`
/// (absorbed into the running turn or delivered, with the prompt), or
/// `popAll` (pulled back into the input with Up). Other lines are ignored.
public struct ClaudeQueuedPromptLedger: Sendable, Equatable {
    /// Longest queue tracked; Claude's own queue is far shorter in practice.
    public static let maximumTrackedPrompts = 64

    private static let marker = Data(#""queue-operation""#.utf8)

    /// Queued prompt texts, oldest first.
    public private(set) var pending: [String] = []

    public init() {}

    /// Number of prompts waiting in the queue.
    public var count: Int { pending.count }

    /// Folds one transcript line (without its trailing newline).
    ///
    /// - Returns: `true` when the queue changed.
    @discardableResult
    public mutating func apply(line: Data) -> Bool {
        guard line.range(of: Self.marker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "queue-operation",
              let operation = object["operation"] as? String else {
            return false
        }
        let content = object["content"] as? String
        switch operation {
        case "enqueue":
            guard pending.count < Self.maximumTrackedPrompts else { return false }
            pending.append(content ?? "")
            return true
        case "dequeue":
            guard !pending.isEmpty else { return false }
            pending.removeFirst()
            return true
        case "remove":
            guard !pending.isEmpty else { return false }
            if let content, let index = pending.firstIndex(of: content) {
                pending.remove(at: index)
            } else {
                pending.removeFirst()
            }
            return true
        case "popAll":
            guard !pending.isEmpty else { return false }
            pending.removeAll()
            return true
        default:
            return false
        }
    }
}
