/// A JSON message consumed by the macOS host from the relay.
public enum ShareServerMessage: Equatable, Sendable {
    /// Authoritative state after connection or resynchronization.
    case sessionState(ShareSessionSnapshot)

    /// A participant waiting for host approval.
    case accessRequest(user: String, email: String)

    /// Current participant presence and roles.
    case presence(participants: [ShareParticipant])

    /// A participant cursor update.
    case cursor(user: String, pos: ShareCursorPos?)

    /// One chat message.
    case chat(ShareChatMessage)

    /// Terminal input requested by an editor.
    case guestInput(user: String, ws: String, pane: String, data: String)

    /// Subscriber-count update for a terminal pane.
    case guestSub(ws: String, pane: String, count: Int)

    /// Requests a fresh hello and full terminal frames.
    case resync

    /// Requests flow-control credit for the immediately preceding payload.
    case ackRequest(nonce: ShareAckNonce)

    /// Reports that the session ended.
    case sessionEnded(reason: String)

    /// Reports a structured relay error.
    case error(code: String, message: String)

    /// Preserves forward compatibility with an unrecognized discriminator.
    case unknown(type: String)
}

extension ShareServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case t
        case user
        case email
        case participants
        case pos
        case msg
        case ws
        case pane
        case data
        case count
        case reason
        case code
        case message
        case nonce
    }

    /// Decodes a relay message using the existing TypeScript v1 discriminator and field names.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .t)
        switch type {
        case "session-state":
            self = .sessionState(try ShareSessionSnapshot(from: decoder))
        case "access-request":
            self = .accessRequest(
                user: try container.decode(String.self, forKey: .user),
                email: try container.decode(String.self, forKey: .email)
            )
        case "presence":
            self = .presence(
                participants: try container.decode([ShareParticipant].self, forKey: .participants)
            )
        case "cursor":
            self = .cursor(
                user: try container.decode(String.self, forKey: .user),
                pos: try container.decodeIfPresent(ShareCursorPos.self, forKey: .pos)
            )
        case "chat":
            self = .chat(try container.decode(ShareChatMessage.self, forKey: .msg))
        case "guest-input":
            self = .guestInput(
                user: try container.decode(String.self, forKey: .user),
                ws: try container.decode(String.self, forKey: .ws),
                pane: try container.decode(String.self, forKey: .pane),
                data: try container.decode(String.self, forKey: .data)
            )
        case "guest-sub":
            self = .guestSub(
                ws: try container.decode(String.self, forKey: .ws),
                pane: try container.decode(String.self, forKey: .pane),
                count: try container.decode(Int.self, forKey: .count)
            )
        case "resync":
            self = .resync
        case "ack-request":
            self = .ackRequest(
                nonce: try container.decode(ShareAckNonce.self, forKey: .nonce)
            )
        case "session-ended":
            self = .sessionEnded(reason: try container.decode(String.self, forKey: .reason))
        case "error":
            self = .error(
                code: try container.decode(String.self, forKey: .code),
                message: try container.decode(String.self, forKey: .message)
            )
        default:
            self = .unknown(type: type)
        }
    }
}
