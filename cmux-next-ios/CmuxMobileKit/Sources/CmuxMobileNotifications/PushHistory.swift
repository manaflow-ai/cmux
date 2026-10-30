import Foundation

/// The conversation the long-press view shows: the last messages up to and
/// including the one the notification is about, oldest first, each once.
///
/// The push carries the notified message (`body`, or the turn's last lines in
/// `tail`); the app's saved chat (`PushSnapshot`) carries what came before.
/// The two overlap only when the app saved the chat after the message
/// arrived; `tail` is the same message cut into lines, so neither is shown
/// next to the other as is (that drew the same reply twice). A chat saved
/// before the notification never holds it: an earlier message that reads the
/// same ("Done.") is another reply, and the notified one follows the chat.
public struct PushHistory: Sendable, Equatable {
    /// At most this many messages; the view scrolls when they are taller than it.
    public static let limit = 4

    public var messages: [PushSnapshot.Message]
    /// The notified message's index in `messages`; nil for an ask, whose
    /// question shows under the history instead.
    public var notifiedIndex: Int?

    /// `notifiedAt`: when the notification arrived (nil: unknown, the chat may hold it).
    public init(payload: PushPayload, snapshot: PushSnapshot?, notifiedAt: Date? = nil, limit: Int = PushHistory.limit) {
        let notified = Self.notified(payload)
        var base = snapshot?.messages ?? []
        if base.isEmpty, let context = Self.context(payload) { base = [context] }
        guard let notified else {
            messages = Array(base.suffix(limit))
            notifiedIndex = nil
            return
        }
        let savedAfter = snapshot.map { snapshot in notifiedAt.map { snapshot.updatedAt >= $0 } ?? true } ?? false
        if savedAfter, let index = base.lastIndex(where: { $0.role == notified.role && Self.same($0.text, notified.text) }) {
            // Saved after it arrived: the history ends at it (later messages are not this notification's).
            base = Array(base[...index])
            if notified.text.count > base[index].text.count { base[index].text = notified.text }
        } else {
            base.append(notified)
        }
        messages = Array(base.suffix(limit))
        notifiedIndex = messages.count - 1
    }

    /// The message the push is about: a reply, a finished turn's last lines, or an error.
    static func notified(_ payload: PushPayload) -> PushSnapshot.Message? {
        switch payload.kind {
        case .chief, .completed:
            let text = payload.body ?? payload.tail.joined(separator: "\n")
            return text.isEmpty ? nil : .init(role: .agent, text: text)
        case .failed:
            return payload.body.map { .init(role: .system, text: $0) }
        case .question, .permission, .terminal:
            return nil
        }
    }

    /// Without a saved chat: the turn's last lines as one message, when they
    /// are not the notified message itself.
    static func context(_ payload: PushPayload) -> PushSnapshot.Message? {
        switch payload.kind {
        case .question, .permission, .failed:
            let text = payload.tail.joined(separator: "\n")
            return text.isEmpty ? nil : .init(role: .agent, text: text)
        case .chief, .completed, .terminal:
            return nil
        }
    }

    /// The same message, though either side may be cut (the snapshot at 280
    /// characters, the push at 400, a line at 160) or re-wrapped.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = normalized(a), y = normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        let shorter = min(x.count, y.count)
        return x.prefix(shorter) == y.prefix(shorter) && shorter >= min(24, max(x.count, y.count))
    }

    private static func normalized(_ text: String) -> String {
        var out = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while out.hasSuffix("…") || out.hasSuffix("...") { out = String(out.dropLast(out.hasSuffix("…") ? 1 : 3)) }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
