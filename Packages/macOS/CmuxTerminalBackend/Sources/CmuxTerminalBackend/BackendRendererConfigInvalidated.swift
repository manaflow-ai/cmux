/// Canonical SHA-256 identity for one daemon-owned renderer configuration.
public struct BackendRendererConfigDigest: Codable, CustomStringConvertible, Equatable,
    Hashable, Sendable
{
    private let value: String

    public init(validating value: String) throws {
        let bytes = value.utf8
        guard bytes.count == 64,
              bytes.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              })
        else { throw BackendProtocolError.malformedMessage }
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(validating: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "renderer config digest must be 64 lowercase hex characters"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Session-wide notice that live renderer presentations use stale configuration.
public struct BackendRendererConfigInvalidated: Decodable, Equatable, Sendable {
    public let revision: UInt64
    public let digest: BackendRendererConfigDigest
    public let reason: String
    public let defaultColors: [String: BackendJSONValue]

    public init(
        revision: UInt64,
        digest: BackendRendererConfigDigest,
        reason: String,
        defaultColors: [String: BackendJSONValue]
    ) throws {
        guard revision > 0, !reason.isEmpty else {
            throw BackendProtocolError.malformedMessage
        }
        self.revision = revision
        self.digest = digest
        self.reason = reason
        self.defaultColors = defaultColors
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let revision = try container.decode(UInt64.self, forKey: .revision)
        let digest = try container.decode(BackendRendererConfigDigest.self, forKey: .digest)
        let reason = try container.decode(String.self, forKey: .reason)
        let defaultColors = try container.decode(
            [String: BackendJSONValue].self,
            forKey: .defaultColors
        )
        do {
            try self.init(
                revision: revision,
                digest: digest,
                reason: reason,
                defaultColors: defaultColors
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .revision,
                in: container,
                debugDescription: "renderer config invalidation has an invalid revision or reason"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case digest
        case reason
        case defaultColors = "default_colors"
    }
}
