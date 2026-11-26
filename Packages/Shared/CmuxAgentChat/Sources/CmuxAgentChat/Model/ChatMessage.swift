import Foundation

/// One item in a conversation transcript: a prompt, a piece of agent prose,
/// a tool run, a diff, an actionable request, or a lifecycle transition.
///
/// `ChatMessage` is a pure value shared across platforms and across the
/// wire: the Mac-side transcript service produces it, the mobile RPC layer
/// transports it, and both the iOS and (future) macOS chat surfaces render
/// it. Rendering decisions are keyed off ``kind``.
public struct ChatMessage: Identifiable, Sendable, Equatable, Codable {
    /// Stable identity for the message, unique within its session.
    ///
    /// For transcript-derived messages this is the transcript entry's own
    /// UUID when available, otherwise a deterministic value derived from
    /// ``seq``. Stability matters: SwiftUI diffing and read-state tracking
    /// both key off it.
    public let id: String

    /// Monotonic position of the message within the session transcript.
    ///
    /// Doubles as the pagination cursor: history pages are requested as
    /// "messages before seq N". Derived from the transcript line index on
    /// the producing side.
    public let seq: Int

    /// Who authored the message.
    public let role: ChatRole

    /// When the message was produced, from the transcript when available.
    public let timestamp: Date

    /// The typed payload that decides how the message renders.
    public let kind: ChatMessageKind

    /// Creates a chat message.
    ///
    /// - Parameters:
    ///   - id: Stable unique identity within the session.
    ///   - seq: Monotonic transcript position, used as the paging cursor.
    ///   - role: Who authored the message.
    ///   - timestamp: When the message was produced.
    ///   - kind: Typed payload deciding the rendering.
    public init(id: String, seq: Int, role: ChatRole, timestamp: Date, kind: ChatMessageKind) {
        self.id = id
        self.seq = seq
        self.role = role
        self.timestamp = timestamp
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case seq
        case role
        case timestamp
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // id and seq are genuinely load-bearing (identity, paging cursor);
        // their absence is corruption and throws. Everything else fails
        // open so one evolved field can't sink a whole page.
        self.id = try container.decode(String.self, forKey: .id)
        self.seq = try container.decode(Int.self, forKey: .seq)
        let rawRole = try? container.decode(String.self, forKey: .role)
        self.role = rawRole.flatMap(ChatRole.init(rawValue:)) ?? .agent
        self.timestamp = (try? container.decode(Date.self, forKey: .timestamp))
            ?? Date(timeIntervalSince1970: 0)
        self.kind = (try? container.decode(ChatMessageKind.self, forKey: .kind))
            ?? .unsupported(ChatUnsupportedPayload(rawType: "undecodable"))
    }
}
