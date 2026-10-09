/// `error`: a read or protocol failure in the shared error shape; `id` names the failed `read`.
public struct ErrorFrame: Hashable, Sendable, Codable {
    public var id: Int?
    public var code: String
    public var message: String
    public var retryable: Bool
    public var details: JSONValue?

    public init(id: Int? = nil, code: String, message: String, retryable: Bool, details: JSONValue? = nil) {
        self.id = id
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}
