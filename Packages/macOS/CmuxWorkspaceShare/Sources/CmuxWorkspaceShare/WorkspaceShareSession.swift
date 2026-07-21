public import Foundation

/// Credentials and endpoints returned when the Mac creates a workspace share.
public struct WorkspaceShareSession: Codable, Equatable, Sendable {
    /// High-entropy public room locator.
    public let shareId: String
    /// Authenticated web viewer URL.
    public let shareUrl: URL
    /// Host WebSocket endpoint.
    public let socketUrl: URL
    /// Per-room host capability required in addition to Stack authentication.
    public let hostCapability: String
    /// Server expiry in Unix milliseconds.
    public let expiresAt: Int64

    /// Creates a share session.
    /// - Parameters:
    ///   - shareId: High-entropy room locator.
    ///   - shareUrl: Viewer URL.
    ///   - socketUrl: Host WebSocket URL.
    ///   - hostCapability: Per-room host capability.
    ///   - expiresAt: Server expiry in Unix milliseconds.
    public init(
        shareId: String,
        shareUrl: URL,
        socketUrl: URL,
        hostCapability: String,
        expiresAt: Int64
    ) {
        self.shareId = shareId
        self.shareUrl = shareUrl
        self.socketUrl = socketUrl
        self.hostCapability = hostCapability
        self.expiresAt = expiresAt
    }
}
