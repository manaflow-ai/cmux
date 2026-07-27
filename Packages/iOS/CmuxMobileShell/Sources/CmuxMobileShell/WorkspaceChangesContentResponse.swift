internal import Foundation

/// Decodes an artifact-compatible response plus an additive content fingerprint.
struct WorkspaceChangesContentResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    /// Artifact-compatible response value decoded from the flat payload.
    let value: Value
    /// Identity-bearing filesystem fingerprint, when supplied by the host.
    let contentFingerprint: String?

    private enum CodingKeys: String, CodingKey {
        case contentFingerprint = "content_fingerprint"
    }

    /// Decodes the wrapped value and additive field from the same flat object.
    init(from decoder: any Decoder) throws {
        value = try Value(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .contentFingerprint
        )
    }
}
