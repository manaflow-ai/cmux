import Foundation

/// One variable of a Cloud environment (CloudDO's `CloudEnvironmentVariable`): a plain `value`, baked
/// into the snapshot, or a `secret` naming a vault item whose value never enters the snapshot.
public nonisolated struct CloudEnvironmentVariable: Codable, Equatable, Sendable {
    public var name: String
    public var value: String?
    public var secret: String?

    private enum CodingKeys: String, CodingKey { case name, value, secret }

    public init(name: String, value: String? = nil, secret: String? = nil) {
        self.name = name
        self.value = value
        self.secret = secret
    }

    /// Writes only the side it has: CloudDO takes `{name, value}` or `{name, secret}`.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(secret, forKey: .secret)
    }
}
