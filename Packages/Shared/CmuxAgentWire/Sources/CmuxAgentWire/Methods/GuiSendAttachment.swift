/// Describes one attachment associated with a send request.
public struct GuiSendAttachment: Codable, Hashable, Sendable {
    /// The open attachment kind string.
    public let kind: String
    /// The attachment's encoded byte count.
    public let byteCount: Int

    private enum CodingKeys: String, CodingKey {
        case kind
        case byteCount = "byte_count"
    }

    /// Creates an attachment descriptor.
    /// - Parameters:
    ///   - kind: The open attachment kind string.
    ///   - byteCount: The encoded byte count.
    public init(kind: String, byteCount: Int) {
        self.kind = kind
        self.byteCount = byteCount
    }
}
