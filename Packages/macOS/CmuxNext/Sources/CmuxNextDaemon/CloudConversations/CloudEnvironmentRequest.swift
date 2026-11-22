import Foundation

/// The Cloud environment editor over the existing daemon HTTP transport.
/// Only the verified native app supplies the platform origin and install bearer.
/// Rust maps these actions to platform REST routes; Swift owns no HTTP client.
public struct CloudEnvironmentRequest: DaemonRequest, VerbatimFieldsRequest, CustomStringConvertible {
    public typealias Response = JSONValue
    public static let command = "cloud-environment"
    public static let requiredCapability: String? = "cloud-environments-v1"
    public let action: String
    public let params: JSONValue
    public let platformOrigin: String
    public let accessToken: String
    enum CodingKeys: String, CodingKey {
        case action, platformOrigin, accessToken
    }

    var verbatimFields: [String: JSONValue] { ["params": params] }
    public var description: String { "CloudEnvironmentRequest([redacted])" }

    public init(action: String, params: JSONValue, platformOrigin: String, accessToken: String) {
        self.action = action
        self.params = params
        self.platformOrigin = platformOrigin
        self.accessToken = accessToken
    }
}
