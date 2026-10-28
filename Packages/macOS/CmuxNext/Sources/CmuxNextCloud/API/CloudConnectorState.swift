public import Foundation

/// The lifecycle states returned by `GET /v1/connectors`.
public enum CloudConnectorState: String, Codable, Equatable, Sendable {
    case available
    case installed
    case needsAuth = "needs-auth"
    case expired
}

