/// A per-Mac section of the aggregated all-devices workspace list.
///
/// A pure value snapshot: it carries the device identity, display name,
/// connectivity status, and that Mac's workspaces, with no reference back to the
/// shell store. This is what lets the grouped `List` honour the snapshot
/// boundary, rows and section headers receive immutable values plus action
/// closures rather than an `@Observable` store reference.
public struct MobileWorkspaceDeviceSection: Identifiable, Equatable, Sendable {
    /// Stable identifier of the paired Mac this section represents.
    public var deviceID: String
    /// Human-readable name of the Mac, shown in the section header.
    public var displayName: String
    /// The Mac's current list-section connectivity status.
    public var status: MobileMacConnectionStatus
    /// Whether this Mac is the active (live heavy-session) Mac.
    public var isActive: Bool
    /// The Mac's workspaces, in display order.
    public var workspaces: [MobileWorkspacePreview]

    /// The device id doubles as the stable `Identifiable` id.
    public var id: String { deviceID }

    /// Whether this section's Mac is reachable for live control.
    ///
    /// `true` only when the Mac is `.connected`; `.reconnecting` and
    /// `.unavailable` Macs are shown grayed and grouped as unavailable.
    public var isReachable: Bool {
        status == .connected
    }

    /// Creates a device section snapshot.
    /// - Parameters:
    ///   - deviceID: Stable identifier of the paired Mac.
    ///   - displayName: Human-readable Mac name for the section header.
    ///   - status: The Mac's list-section connectivity status.
    ///   - isActive: Whether this is the active (heavy-session) Mac.
    ///   - workspaces: The Mac's workspaces, in display order.
    public init(
        deviceID: String,
        displayName: String,
        status: MobileMacConnectionStatus,
        isActive: Bool,
        workspaces: [MobileWorkspacePreview]
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.status = status
        self.isActive = isActive
        self.workspaces = workspaces
    }
}
