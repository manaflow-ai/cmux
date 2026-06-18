public import CMUXMobileCore
public import Foundation

/// A Mac paired with this iOS device, persisted across launches.
///
/// Auth tokens are never persisted, only enough to re-mint a fresh attach
/// ticket via the StackAuth-authenticated manual host flow on next launch.
public struct MobilePairedMac: Codable, Equatable, Sendable, Identifiable {
    /// Stable identifier of the paired Mac device.
    public var macDeviceID: String
    /// Human-readable name of the Mac, if the pairing payload supplied one.
    public var displayName: String?
    /// Attach routes advertised by the Mac, ordered by priority (lowest first).
    public var routes: [CmxAttachRoute]
    /// When this pairing was first recorded.
    public var createdAt: Date
    /// When this pairing was last refreshed or used.
    public var lastSeenAt: Date
    /// Whether this is the currently active pairing for its Stack user scope.
    public var isActive: Bool
    /// Stack Auth user that owns this pairing, if any.
    public var stackUserID: String?

    /// The Mac device identifier doubles as the stable `Identifiable` id.
    public var id: String { macDeviceID }

    /// Creates a paired-Mac value.
    /// - Parameters:
    ///   - macDeviceID: Stable identifier of the paired Mac device.
    ///   - displayName: Optional human-readable Mac name.
    ///   - routes: Attach routes advertised by the Mac.
    ///   - createdAt: When the pairing was first recorded.
    ///   - lastSeenAt: When the pairing was last refreshed.
    ///   - isActive: Whether this pairing is currently active for its scope.
    ///   - stackUserID: Owning Stack Auth user, if any.
    public init(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool,
        stackUserID: String?
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
        self.stackUserID = stackUserID
    }
}
