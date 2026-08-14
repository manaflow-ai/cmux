public import Foundation

/// Applies the shared usability and replacement rules for portal hosts.
///
/// Terminal and browser portals use this policy so a detached or effectively
/// zero-sized representable cannot displace a host that is still presenting the
/// surface.
public struct PortalHostLeasePolicy: Sendable {
    private let minimumArea: CGFloat

    /// Creates a portal host lease policy.
    ///
    /// - Parameter minimumArea: The area a window-attached host must exceed to
    ///   participate in ownership replacement. Negative values are clamped to zero.
    public init(minimumArea: CGFloat = 4) {
        self.minimumArea = max(0, minimumArea)
    }

    /// Returns the nonnegative area represented by a host's bounds.
    ///
    /// - Parameter bounds: The host bounds reported by its representable.
    /// - Returns: The product of the nonnegative width and height.
    public func area(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    /// Returns whether a lease represents an attached host with meaningful area.
    ///
    /// - Parameter lease: The portal host lease to evaluate.
    /// - Returns: `true` when the host is window-attached and exceeds the configured area.
    public func isUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > minimumArea
    }

    /// Returns whether a candidate may replace the current portal host.
    ///
    /// The current host may always refresh its own lease. A distinct host must be
    /// usable before it can replace ownership, including during a cross-pane move.
    ///
    /// - Parameters:
    ///   - current: The lease that currently owns the portal.
    ///   - candidate: The lease requesting ownership.
    ///   - allowsSamePaneReplacement: Whether renderer-specific rules authorize a
    ///     distinct candidate in the same pane to supersede the current host.
    /// - Returns: `true` when the candidate may become the active lease.
    public func shouldReplace(
        current: PortalHostLease,
        with candidate: PortalHostLease,
        allowsSamePaneReplacement: Bool
    ) -> Bool {
        if current.hostId == candidate.hostId {
            return true
        }

        guard isUsable(candidate) else { return false }
        return current.paneId != candidate.paneId
            || !isUsable(current)
            || allowsSamePaneReplacement
    }
}
