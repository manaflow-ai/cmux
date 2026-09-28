import Foundation

/// Tracks the prompts waiting in Claude Code's input queue that Up can move
/// back into the input, from the session transcript's `queue-operation` lines.
///
/// Claude Code writes `enqueue` (with the prompt) when you send while a turn
/// runs, then `dequeue` (sent as the next turn, no content), `remove` (absorbed
/// into the running turn or delivered, with the prompt), or one `popAll` per
/// prompt that Up pulled back into the input, each with that prompt.
///
/// Claude also queues its own background task notifications and queued shell
/// commands. Up doesn't pull those back, and notifications are often never
/// resolved in the transcript, so lines for them are ignored.
public struct ClaudeQueuedPromptLedger: Sendable, Equatable {
    /// Longest queue tracked; Claude's own queue is far shorter in practice.
    public static let maximumTrackedPrompts = 64

    private static let marker = Data(#""queue-operation""#.utf8)
    private static let uneditablePrefixes = ["<task-notification>", "<bash-input>"]

    /// Queued prompt texts, oldest first.
    public private(set) var pending: [String] = []

    public init() {}

    /// Number of queued prompts Up would move back into the input.
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
        if let content, Self.uneditablePrefixes.contains(where: content.hasPrefix) {
            return false
        }
        switch operation {
        case "enqueue":
            guard let content, pending.count < Self.maximumTrackedPrompts else { return false }
            pending.append(content)
            return true
        case "dequeue", "remove", "popAll":
            guard !pending.isEmpty else { return false }
            if let content, let index = pending.firstIndex(of: content) {
                pending.remove(at: index)
            } else {
                pending.removeFirst()
            }
            return true
        default:
            return false
        }
    }
}
