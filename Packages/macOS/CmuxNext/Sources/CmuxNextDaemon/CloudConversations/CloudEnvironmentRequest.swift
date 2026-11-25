public import Foundation

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

/// A team environment's id and name, as `cmux cloud new-machine --environment NAME` resolves it.
public struct CloudEnvironmentName: Equatable, Sendable {
    public let id: String
    public let name: String
}

extension CloudEnvironmentRequest {
    /// The team's environments from `/v1/cloud-environments` (`list`), the store the composer's chip and editor use. No
    /// connection or platform throws, like a list that fails: a name then names none yet, never an empty list.
    public static func names(connection: DaemonConnection?, platform: URL?, accessToken: String) async throws -> [CloudEnvironmentName] {
        guard let connection, let platform else { throw DaemonError.notConnected }
        let answer = try await connection.request(Self(action: "list", params: .object([:]), platformOrigin: platform.absoluteString,
                                                       accessToken: accessToken), timeout: .seconds(30))
        return (answer.arrayValue ?? []).compactMap { value in
            guard let id = value["id"]?.stringValue, let name = value["name"]?.stringValue else { return nil }
            return CloudEnvironmentName(id: id, name: name)
        }
    }
}
