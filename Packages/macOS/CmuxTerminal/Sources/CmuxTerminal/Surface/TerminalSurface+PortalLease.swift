public import Foundation
public import CmuxTerminalCore
public import Bonsplit
#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Portal-host leases (which pane host currently owns the surface)

extension TerminalSurface {
    /// The current portal lifecycle generation (bumped on ownership and close transitions).
    public func portalBindingGeneration() -> UInt64 {
        portalLifecycleGeneration
    }

    /// The current portal lifecycle state label.
    public func portalBindingStateLabel() -> String {
        portalLifecycleState.rawValue
    }

    /// Whether a portal may bind this surface for the expected id/generation.
    public func canAcceptPortalBinding(expectedSurfaceId: UUID?, expectedGeneration: UInt64?) -> Bool {
        guard portalLifecycleState == .live else { return false }
        if let expectedSurfaceId, expectedSurfaceId != id {
            return false
        }
        if let expectedGeneration, expectedGeneration != portalLifecycleGeneration {
            return false
        }
        return true
    }

    static let portalHostAreaThreshold: CGFloat = 4

    static func portalHostArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    static func portalHostIsUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > portalHostAreaThreshold
    }

    /// The model ownership epoch used before representable creation order breaks ties.
    public func currentPortalHostOwnershipGeneration() -> UInt64 {
        portalLifecycleGeneration
    }

    /// Keeps retired representable hosts from reclaiming the surface after a
    /// newer host has taken authority. The model epoch supersedes host creation
    /// order so a legitimate rollback can still return to an older host.
    private func reservePortalHostAuthority(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        instanceSerial: UInt64,
        ownershipGeneration: UInt64
    ) -> Bool {
        if let current = portalHostAuthority {
            if current.hostId == hostId, current.instanceSerial == instanceSerial {
                guard ownershipGeneration >= current.ownershipGeneration else { return false }
                if current.paneId == paneId.id,
                   current.ownershipGeneration == ownershipGeneration {
                    return true
                }
            } else {
                guard ownershipGeneration >= current.ownershipGeneration else { return false }
                if ownershipGeneration == current.ownershipGeneration,
                   instanceSerial <= current.instanceSerial {
                    return false
                }
            }
        }

        portalHostAuthority = TerminalPortalHostAuthority(
            hostId: hostId,
            paneId: paneId.id,
            instanceSerial: instanceSerial,
            ownershipGeneration: ownershipGeneration
        )
        return true
    }

    /// Re-arms the lease when SwiftUI is about to rebuild the owning host.
    @discardableResult
    public func preparePortalHostReplacementIfOwned(hostId: ObjectIdentifier, reason: String) -> Bool {
        guard let current = activePortalHostLease, current.hostId == hostId else { return false }
        // SwiftUI can tear down and rebuild the host NSView during split churn. Keep the
        // existing portal binding alive, but make the old lease non-usable so the next
        // distinct host in the same pane can claim immediately instead of waiting for a
        // later layout-follow-up retry.
        activePortalHostLease = PortalHostLease(
            hostId: current.hostId,
            paneId: current.paneId,
            instanceSerial: current.instanceSerial,
            inWindow: false,
            area: current.area
        )
#if DEBUG
        logDebugEvent(
            "terminal.portal.host.rearm surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
        return true
    }

    /// Claims (or re-claims) the portal host for a pane.
    ///
    /// - Returns: Whether the claim won ownership.
    public func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        instanceSerial: UInt64,
        ownershipGeneration: UInt64 = 0,
        inWindow: Bool,
        bounds: CGRect,
        allowsAuthorityAcquisition: Bool = true,
        reason: String
    ) -> Bool {
        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            instanceSerial: instanceSerial,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        let alreadyOwnsLease = activePortalHostLease?.hostId == hostId
        guard alreadyOwnsLease || allowsAuthorityAcquisition else {
#if DEBUG
            logDebugEvent(
                "terminal.portal.host.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "cause=modelIneligible"
            )
#endif
            return false
        }

        if let current = activePortalHostLease {
            if current.hostId == hostId {
                guard reservePortalHostAuthority(
                    hostId: hostId,
                    paneId: paneId,
                    instanceSerial: instanceSerial,
                    ownershipGeneration: ownershipGeneration
                ) else { return false }
                activePortalHostLease = next
                return true
            }

            let currentUsable = Self.portalHostIsUsable(current)
            let nextUsable = Self.portalHostIsUsable(next)
            // During split churn SwiftUI can briefly keep the old host alive while the new
            // host for the same pane is already in the window. Prefer the newer live host
            // immediately so the surface moves with the pane instead of waiting for a later
            // update from unrelated focus/layout work.
            let newerSamePaneHostReady =
                current.paneId == paneId.id &&
                nextUsable &&
                next.instanceSerial > current.instanceSerial
            let newerModelOwnerReady =
                nextUsable &&
                ownershipGeneration > (portalHostAuthority?.ownershipGeneration ?? 0)
            // A dragged terminal must hand off immediately when it moves to a different pane.
            // Waiting for the old host to become "worse" leaves the moved pane blank/stale.
            let shouldReplace =
                current.paneId != paneId.id ||
                !currentUsable ||
                newerSamePaneHostReady ||
                newerModelOwnerReady

            if shouldReplace {
                guard reservePortalHostAuthority(
                    hostId: hostId,
                    paneId: paneId,
                    instanceSerial: instanceSerial,
                    ownershipGeneration: ownershipGeneration
                ) else { return false }
#if DEBUG
                logDebugEvent(
                    "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "inWin=\(inWindow ? 1 : 0) " +
                    "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                    "replacingHost=\(current.hostId) replacingPane=\(current.paneId.uuidString.prefix(5)) " +
                    "replacingInWin=\(current.inWindow ? 1 : 0) " +
                    "replacingArea=\(String(format: "%.1f", current.area))"
                )
#endif
                activePortalHostLease = next
                return true
            }

#if DEBUG
            logDebugEvent(
                "terminal.portal.host.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "inWin=\(inWindow ? 1 : 0) " +
                "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) " +
                "ownerHost=\(current.hostId) ownerPane=\(current.paneId.uuidString.prefix(5)) " +
                "ownerInWin=\(current.inWindow ? 1 : 0) " +
                "ownerArea=\(String(format: "%.1f", current.area))"
            )
#endif
            return false
        }

        guard reservePortalHostAuthority(
            hostId: hostId,
            paneId: paneId,
            instanceSerial: instanceSerial,
            ownershipGeneration: ownershipGeneration
        ) else { return false }
        activePortalHostLease = next
#if DEBUG
        logDebugEvent(
            "terminal.portal.host.claim surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
            "inWin=\(inWindow ? 1 : 0) " +
            "size=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) replacingHost=nil"
        )
#endif
        return true
    }

    /// Releases the lease when the owning host disappears.
    public func releasePortalHostIfOwned(hostId: ObjectIdentifier, reason: String) {
        guard let current = activePortalHostLease, current.hostId == hostId else { return }
        activePortalHostLease = nil
#if DEBUG
        logDebugEvent(
            "terminal.portal.host.release surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "inWin=\(current.inWindow ? 1 : 0) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
    }
}
