import Foundation

/// Carries an attachment transcript entry.
public struct AttachmentPayload: Codable, Hashable, Sendable {
    /// The attachment kind identifier.
    public let kind: String
    /// A compact attachment summary.
    public let summary: String

    private enum CodingKeys: String, CodingKey {
        case kind = "attachment_kind"
        case summary
    }

    /// Creates an attachment payload.
    /// - Parameters:
    ///   - kind: The attachment kind identifier.
    ///   - summary: A compact attachment summary.
    public init(kind: String, summary: String) {
        self.kind = kind
        self.summary = summary
    }
}
