public import Foundation

/// A provider row from `GET /v1/connectors`.
public struct CloudConnectorStatus: Codable, Equatable, Sendable {
    public let provider: String
    public let state: CloudConnectorState

    public init(provider: String, state: CloudConnectorState) {
        self.provider = provider
        self.state = state
    }
}
