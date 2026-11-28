public import Foundation

/// The person's vault (RFD 0222 (c)1, Settings > Environment) over the daemon's `vault-env` op.
/// Only the verified native app supplies the platform origin and install bearer, as for
/// ``CloudEnvironmentRequest``. A `set` carries a secret value in `params`: the daemon encodes it,
/// fingerprints it and wipes it; nothing here logs or keeps it.
public struct VaultEnvRequest: DaemonRequest, VerbatimFieldsRequest, CustomStringConvertible {
    public typealias Response = JSONValue
    public static let command = "vault-env"
    public static let requiredCapability: String? = "vault-env-v1"
    /// `list`, `set`, `policy`, `rm` or `grants`.
    public let action: String
    public let params: JSONValue
    public let platformOrigin: String
    public let accessToken: String
    enum CodingKeys: String, CodingKey {
        case action, platformOrigin, accessToken
    }

    var verbatimFields: [String: JSONValue] { ["params": params] }
    public var description: String { "VaultEnvRequest([redacted])" }

    public init(action: String, params: JSONValue, platformOrigin: String, accessToken: String) {
        self.action = action
        self.params = params
        self.platformOrigin = platformOrigin
        self.accessToken = accessToken
    }
}
