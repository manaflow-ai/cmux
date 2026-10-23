/// One `cmux.wire/1` stream ``WireHomeSource`` subscribes to.
enum HomeWireStreamTarget: Hashable, Sendable {
    /// The user's inbox (`/v1/wire/user`, stream `inbox:<user>`).
    case inbox
    /// One conversation (`/v1/wire/conv/<id>`, stream `conv:<id>`).
    case conversation(ConversationID)

    /// The socket's path under the server's base URL.
    var path: String {
        switch self {
        case .inbox: "/v1/wire/user"
        case .conversation(let id): "/v1/wire/conv/\(id.rawValue)"
        }
    }

    /// The stream name the owner puts on its frames; the inbox's needs the
    /// principal's user (from `welcome`).
    func streamName(user: String?) -> String? {
        switch self {
        case .inbox: user.map { "inbox:\($0)" }
        case .conversation(let id): "conv:\(id.rawValue)"
        }
    }
}
