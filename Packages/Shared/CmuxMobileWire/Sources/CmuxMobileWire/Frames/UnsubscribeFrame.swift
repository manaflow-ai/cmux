/// `unsubscribe` (cmux.wire/1).
public struct UnsubscribeFrame: Hashable, Sendable, Codable {
    public var stream: String?

    public init(stream: String? = nil) {
        self.stream = stream
    }
}
