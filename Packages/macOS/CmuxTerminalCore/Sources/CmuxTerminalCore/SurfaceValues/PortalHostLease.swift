public import Foundation

/// The record of which portal host currently presents a surface.
///
/// When multiple hosts compete for one surface (split churn, workspace
/// switches), the lease decides the winner by window attachment and visible
/// area.
public struct PortalHostLease: Sendable {
    /// The identity of the host view holding the lease.
    public let hostId: ObjectIdentifier

    /// The pane the host belongs to.
    public let paneId: UUID

    /// The monotonically increasing serial of the host instance.
    public let instanceSerial: UInt64

    /// Whether the host was attached to a window when it took the lease.
    public let inWindow: Bool

    /// The host's visible area when it took the lease.
    public let area: CGFloat

    /// Creates a lease record for one portal host.
    ///
    /// - Parameters:
    ///   - hostId: The identity of the host view holding the lease.
    ///   - paneId: The pane the host belongs to.
    ///   - instanceSerial: The monotonically increasing host instance serial.
    ///   - inWindow: Whether the host was window-attached at lease time.
    ///   - area: The host's visible area at lease time.
    public init(
        hostId: ObjectIdentifier,
        paneId: UUID,
        instanceSerial: UInt64,
        inWindow: Bool,
        area: CGFloat
    ) {
        self.hostId = hostId
        self.paneId = paneId
        self.instanceSerial = instanceSerial
        self.inWindow = inWindow
        self.area = area
    }
}
