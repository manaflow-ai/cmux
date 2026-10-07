/// A JSON record on a stream-plane channel whose `t` is a catalog `message`
/// (for example `terminal.viewport`); `body` holds every other member.
public struct ChannelMessage: Hashable, Sendable {
    public var name: String
    public var body: [String: JSONValue]

    public init(name: String, body: [String: JSONValue]) {
        self.name = name
        self.body = body
    }

    /// The record object, `t` included.
    public var jsonValue: JSONValue {
        var o = body
        o["t"] = .string(name)
        return .object(o)
    }
}
