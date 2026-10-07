/// `signal`: relayed by HostDO, never stored. The relay overwrites `from`
/// with the sender's authenticated install; a client never sets it.
public struct SignalFrame: Hashable, Sendable, Codable {
    public var kind: SignalKind
    public var session: String
    public var to: String
    public var from: String?
    public var body: [String: JSONValue]

    public init(kind: SignalKind, session: String, to: String, from: String? = nil, body: [String: JSONValue]) {
        self.kind = kind
        self.session = session
        self.to = to
        self.from = from
        self.body = body
    }
}
