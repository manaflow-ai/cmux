/// `read`: a read op over the socket, answered by `read.result` or `error` with the same id.
public struct ReadFrame: Hashable, Sendable, Codable {
    public var id: Int
    public var op: String
    public var params: JSONValue
    public var stream: String?

    public init(id: Int, op: String, params: JSONValue, stream: String? = nil) {
        self.id = id
        self.op = op
        self.params = params
        self.stream = stream
    }
}
