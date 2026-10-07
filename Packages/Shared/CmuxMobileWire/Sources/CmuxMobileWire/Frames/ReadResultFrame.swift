/// `read.result`: the value of a `read` at `revision` (decimal seq).
public struct ReadResultFrame: Hashable, Sendable, Codable {
    public var id: Int
    public var value: JSONValue
    public var revision: String

    public init(id: Int, value: JSONValue, revision: String) {
        self.id = id
        self.value = value
        self.revision = revision
    }
}
