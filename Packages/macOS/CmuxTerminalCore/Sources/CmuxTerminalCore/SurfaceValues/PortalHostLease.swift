public import Foundation

/// The record of which portal host currently presents a surface.
///
/// Authority selection is model-owned; this lease records the geometry and
/// attachment state of the host that currently holds that authority.
public struct PortalHostLease: Sendable {
    /// The identity of the host view holding the lease.
    public let hostId: ObjectIdentifier

    /// The pane the host belongs to.
    public let paneId: UUID

    /// Whether the host was attached to a window when it took the lease.
    public let inWindow: Bool

    /// The host's visible area when it took the lease.
    public let area: CGFloat

    /// Creates a lease record for one portal host.
    ///
    /// - Parameters:
    ///   - hostId: The identity of the host view holding the lease.
    ///   - paneId: The pane the host belongs to.
    ///   - inWindow: Whether the host was window-attached at lease time.
    ///   - area: The host's visible area at lease time.
    public init(
        hostId: ObjectIdentifier,
        paneId: UUID,
        inWindow: Bool,
        area: CGFloat
    ) {
        self.hostId = hostId
        self.paneId = paneId
        self.inWindow = inWindow
        self.area = area
    }
}
