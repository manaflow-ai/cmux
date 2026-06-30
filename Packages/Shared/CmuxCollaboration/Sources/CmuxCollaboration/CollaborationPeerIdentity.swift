public import Foundation

/// Relay-visible identity metadata for one running collaboration peer.
public struct CollaborationPeerIdentity: Equatable, Sendable {
    /// The default color palette used to distinguish peers in collaboration UI.
    public static let defaultColorPalette = ["#7A5CFF", "#0A84FF", "#34C759", "#FF9F0A", "#FF375F"]

    /// A relay-unique peer identifier for this app process.
    public let peerID: String
    /// The display name shown to collaborators.
    public let displayName: String
    /// The display color assigned to this peer.
    public let color: String

    /// Creates peer identity metadata.
    /// - Parameters:
    ///   - peerID: A relay-unique peer identifier.
    ///   - displayName: The display name shown to collaborators.
    ///   - color: The display color assigned to this peer.
    public init(peerID: String, displayName: String, color: String) {
        self.peerID = peerID
        self.displayName = displayName
        self.color = color
    }

    /// Creates a fresh peer identity for a single running app process.
    ///
    /// Collaboration relays key active connections by peer ID, so two local app
    /// windows that join the same session must not reuse a persisted bundle-wide
    /// identifier. Generate this once at process startup and reuse it for that
    /// process's collaboration connections.
    /// - Parameters:
    ///   - displayName: The display name shown to collaborators.
    ///   - colorPalette: The palette used to derive the peer color.
    ///   - idProvider: Supplies the process-local peer UUID.
    /// - Returns: Fresh relay identity metadata for one app process.
    public static func ephemeral(
        displayName: String,
        colorPalette: [String] = Self.defaultColorPalette,
        idProvider: @Sendable () -> UUID = { UUID() }
    ) -> CollaborationPeerIdentity {
        let peerID = idProvider().uuidString
        let palette = colorPalette.isEmpty ? Self.defaultColorPalette : colorPalette
        return CollaborationPeerIdentity(
            peerID: peerID,
            displayName: displayName,
            color: palette[Self.colorIndex(for: peerID, count: palette.count)]
        )
    }

    private static func colorIndex(for peerID: String, count: Int) -> Int {
        let total = peerID.utf8.reduce(0) { partial, byte in
            partial + Int(byte)
        }
        return total % count
    }
}
