public import Foundation
public import CmuxTerminalCore
public import Bonsplit
#if DEBUG
internal import CMUXDebugLog
#endif

// MARK: - Portal-host leases (which pane host currently owns the surface)

@MainActor
extension TerminalSurface {
    /// The current portal binding generation, bumped only by close transitions.
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

    /// Whether a candidate host is attached and large enough to claim portal authority.
    public func portalHostIsUsable(inWindow: Bool, bounds: CGRect) -> Bool {
        inWindow && Self.portalHostArea(for: bounds) > Self.portalHostAreaThreshold
    }

    /// Whether `hostId` currently owns this surface's portal lease.
    public func isPortalHostOwner(hostId: ObjectIdentifier) -> Bool {
        activePortalHostLease?.hostId == hostId
    }

    /// The model-owned epoch that orders portal host ownership changes.
    public func currentPortalHostOwnershipGeneration() -> UInt64 {
        portalHostOwnershipGeneration
    }

    /// Reserves authority by model epoch and explicit host-retirement state.
    /// Host creation order never participates in ownership.
    private func reservePortalHostAuthority(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        ownershipGeneration: UInt64,
        retryWhenAvailable: (@MainActor () -> Void)?
    ) -> Bool {
        if let current = portalHostAuthority {
            guard ownershipGeneration >= current.ownershipGeneration else { return false }
            if ownershipGeneration == current.ownershipGeneration {
                if current.hostId == hostId {
                    pendingPortalHostRetries.removeValue(forKey: hostId)
                    if current.paneId != paneId.id || current.phase != .bound {
                        portalHostAuthority = TerminalPortalHostAuthority(
                            hostId: hostId,
                            paneId: paneId.id,
                            ownershipGeneration: ownershipGeneration,
                            phase: .bound
                        )
                    }
                    return true
                }
                guard current.phase == .replacementAllowed else {
                    if let retryWhenAvailable {
                        pendingPortalHostRetries[hostId] = PendingTerminalPortalHostRetry(
                            hostId: hostId,
                            ownershipGeneration: ownershipGeneration,
                            retry: retryWhenAvailable
                        )
                    }
                    return false
                }
            }
        }

        portalHostAuthority = TerminalPortalHostAuthority(
            hostId: hostId,
            paneId: paneId.id,
            ownershipGeneration: ownershipGeneration,
            phase: .bound
        )
        pendingPortalHostRetries.removeAll()
        return true
    }

    private func allowPortalHostReplacementIfAuthoritative(hostId: ObjectIdentifier) {
        guard let current = portalHostAuthority, current.hostId == hostId else { return }
        portalHostAuthority = TerminalPortalHostAuthority(
            hostId: current.hostId,
            paneId: current.paneId,
            ownershipGeneration: current.ownershipGeneration,
            phase: .replacementAllowed
        )
        let retries = pendingPortalHostRetries.values.filter {
            $0.ownershipGeneration == current.ownershipGeneration
        }
        for retry in retries {
            pendingPortalHostRetries.removeValue(forKey: retry.hostId)
        }
        for retry in retries {
            retry.retry()
        }
    }

    /// Cancels a deferred authority retry when its candidate host is dismantled.
    public func cancelPendingPortalHostRetry(hostId: ObjectIdentifier) {
        pendingPortalHostRetries.removeValue(forKey: hostId)
    }

    /// Drops every deferred candidate when the runtime is torn down, quarantined, or suspended.
    func cancelAllPendingPortalHostRetries() {
        pendingPortalHostRetries.removeAll(keepingCapacity: false)
    }

    /// Re-arms the lease when SwiftUI is about to rebuild the owning host.
    @discardableResult
    public func preparePortalHostReplacementIfOwned(hostId: ObjectIdentifier, reason: String) -> UInt64? {
        guard let current = activePortalHostLease, current.hostId == hostId,
              let authority = portalHostAuthority, authority.hostId == hostId else { return nil }
        // SwiftUI can tear down and rebuild the host NSView during split churn. Keep the
        // existing portal binding alive, but make the old lease non-usable so the next
        // distinct host in the same pane can claim immediately instead of waiting for a
        // later layout-follow-up retry.
        activePortalHostLease = PortalHostLease(
            hostId: current.hostId,
            paneId: current.paneId,
            inWindow: false,
            area: current.area
        )
        allowPortalHostReplacementIfAuthoritative(hostId: hostId)
#if DEBUG
        logDebugEvent(
            "terminal.portal.host.rearm surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
        return authority.ownershipGeneration
    }

    /// Whether an announced replacement still matches the current authority epoch.
    public func isPortalHostReplacementPending(ownershipGeneration: UInt64) -> Bool {
        guard let authority = portalHostAuthority else { return false }
        return authority.ownershipGeneration == ownershipGeneration &&
            authority.phase == .replacementAllowed
    }

    /// Claims (or re-claims) the portal host for a pane.
    ///
    /// - Returns: Whether the claim won ownership.
    public func claimPortalHost(
        hostId: ObjectIdentifier,
        paneId: PaneID,
        ownershipGeneration: UInt64 = 0,
        inWindow: Bool,
        bounds: CGRect,
        retryWhenAvailable: (@MainActor () -> Void)? = nil,
        reason: String
    ) -> Bool {
        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            inWindow: inWindow,
            area: Self.portalHostArea(for: bounds)
        )

        if let current = activePortalHostLease {
            if current.hostId == hostId {
                guard reservePortalHostAuthority(
                    hostId: hostId,
                    paneId: paneId,
                    ownershipGeneration: ownershipGeneration,
                    retryWhenAvailable: retryWhenAvailable
                ) else { return false }
                activePortalHostLease = next
                return true
            }

            guard Self.portalHostIsUsable(next) else {
#if DEBUG
                logDebugEvent(
                    "terminal.portal.host.skip surface=\(id.uuidString.prefix(5)) " +
                    "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                    "cause=detachedOrTiny"
                )
#endif
                return false
            }
            if reservePortalHostAuthority(
                hostId: hostId,
                paneId: paneId,
                ownershipGeneration: ownershipGeneration,
                retryWhenAvailable: retryWhenAvailable
            ) {
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

        guard Self.portalHostIsUsable(next) else { return false }
        guard reservePortalHostAuthority(
            hostId: hostId,
            paneId: paneId,
            ownershipGeneration: ownershipGeneration,
            retryWhenAvailable: retryWhenAvailable
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
        allowPortalHostReplacementIfAuthoritative(hostId: hostId)
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
