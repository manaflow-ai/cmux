/// A JSON message sent from the macOS host to the relay.
public enum ShareHostMessage: Equatable, Sendable {
    /// Initializes relay state after each socket open.
    case hello(shared: [ShareSharedWorkspace], layouts: [ShareWorkspaceLayout])

    /// Publishes one changed workspace layout.
    case layout(ShareWorkspaceLayout)

    /// Publishes the current shared-workspace metadata.
    case shared([ShareSharedWorkspace])

    /// Approves a waiting participant with a role.
    case approve(user: String, role: ShareRole)

    /// Denies a waiting participant.
    case deny(user: String)

    /// Removes a participant from the session.
    case kick(user: String)

    /// Changes an approved participant's role.
    case role(user: String, role: ShareRole)

    /// Publishes the host cursor, or clears it with `nil`.
    case cursor(ShareCursorPos?)

    /// Sends a host chat message.
    case chat(text: String, bubble: ShareCursorPos?)

    /// Publishes the workspace currently viewed by the host.
    case focus(ws: String?)

    /// Returns flow-control credit after accepting the preceding server payload.
    case ack(nonce: ShareAckNonce)

    /// Ends the session.
    case end
}

extension ShareHostMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case t
        case proto
        case shared
        case layouts
        case layout
        case user
        case role
        case pos
        case text
        case bubble
        case ws
        case nonce
    }

    /// Encodes a host message using the existing TypeScript v1 discriminator and field names.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let shared, let layouts):
            try container.encode("hello", forKey: .t)
            try container.encode(ShareProtocolConstants.version, forKey: .proto)
            try container.encode(shared, forKey: .shared)
            try container.encode(layouts, forKey: .layouts)
        case .layout(let layout):
            try container.encode("layout", forKey: .t)
            try container.encode(layout, forKey: .layout)
        case .shared(let shared):
            try container.encode("shared", forKey: .t)
            try container.encode(shared, forKey: .shared)
        case .approve(let user, let role):
            try container.encode("approve", forKey: .t)
            try container.encode(user, forKey: .user)
            try container.encode(role, forKey: .role)
        case .deny(let user):
            try container.encode("deny", forKey: .t)
            try container.encode(user, forKey: .user)
        case .kick(let user):
            try container.encode("kick", forKey: .t)
            try container.encode(user, forKey: .user)
        case .role(let user, let role):
            try container.encode("role", forKey: .t)
            try container.encode(user, forKey: .user)
            try container.encode(role, forKey: .role)
        case .cursor(let pos):
            try container.encode("cursor", forKey: .t)
            if let pos {
                try container.encode(pos, forKey: .pos)
            } else {
                try container.encodeNil(forKey: .pos)
            }
        case .chat(let text, let bubble):
            try container.encode("chat", forKey: .t)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(bubble, forKey: .bubble)
        case .focus(let ws):
            try container.encode("focus", forKey: .t)
            if let ws {
                try container.encode(ws, forKey: .ws)
            } else {
                try container.encodeNil(forKey: .ws)
            }
        case .ack(let nonce):
            try container.encode("ack", forKey: .t)
            try container.encode(nonce, forKey: .nonce)
        case .end:
            try container.encode("end", forKey: .t)
        }
    }
}
