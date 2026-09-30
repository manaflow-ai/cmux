import Foundation

/// Versioned host messages for the direct React acpmux client.
public enum AcpmuxWebBridgeProtocol {
    public static let version = 1
}

/// Configuration returned by the host after the page is ready. The daemon bearer
/// token is handed to this local web-view launch and is never persisted by Swift.
public struct AcpmuxWebHostHandshake: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let transport: String
    public let endpoint: String
    public let token: String
    public let sessionId: String?

    public init(endpoint: String, token: String, sessionId: String?) {
        protocolVersion = AcpmuxWebBridgeProtocol.version
        transport = "acpmux-websocket"
        self.endpoint = endpoint
        self.token = token
        self.sessionId = sessionId
    }
}
