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
        guard portalLifecycleState == .live, !runtimeSurfaceSuspendedForAgentHibernation else { return false }
        if let expectedSurfaceId, expectedSurfaceId != id {
            return false
        }
        if let expectedGeneration, expectedGeneration != portalLifecycleGeneration {
            return false
        }
        return true
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
    public func preparePortalHostReplacementIfOwned(
        hostId: ObjectIdentifier,
        instanceSerial: UInt64,
        reason: String
    ) -> Bool {
        // The serial authenticates the vacating incarnation: ObjectIdentifier
        // values are reused after dealloc, so a stale vacate from an earlier
        // object at the same address must not re-arm the lease or clear a
        // newer host's authority.
        guard let current = activePortalHostLease,
              current.hostId == hostId,
              current.instanceSerial == instanceSerial else { return false }
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
        clearPortalHostAuthorityIfHeld(by: hostId, instanceSerial: current.instanceSerial)
        notifyPortalHostVacated(vacatedHostId: hostId, instanceSerial: current.instanceSerial)
#if DEBUG
        logDebugEvent(
            "terminal.portal.host.rearm surface=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) host=\(hostId) pane=\(current.paneId.uuidString.prefix(5)) " +
            "area=\(String(format: "%.1f", current.area))"
        )
#endif
        return true
    }

    /// Drops host-authority supremacy when the authority holder itself vacates.
    ///
    /// The authority record exists to stop a retired host from stealing the
    /// surface back from the host that replaced it. Once the replacement host
    /// is dismantled there is nobody left to protect, but its record would
    /// still outrank every live host with an older creation serial at the same
    /// ownership generation — claimPortalHost decides "replace" yet the
    /// reservation refuses, and the surface stays pinned to a dead host's
    /// final anchor until an unrelated model-generation bump.
    ///
    /// Matched on host AND creation serial: a stale vacate from an earlier
    /// incarnation of the same host object must not erase a newer record.
    private func clearPortalHostAuthorityIfHeld(by hostId: ObjectIdentifier, instanceSerial: UInt64) {
        guard let authority = portalHostAuthority,
              authority.hostId == hostId,
              authority.instanceSerial == instanceSerial else { return }
        portalHostAuthority = nil
#if DEBUG
        logDebugEvent(
            "terminal.portal.host.authorityCleared surface=\(id.uuidString.prefix(5)) " +
            "host=\(hostId) pane=\(authority.paneId.uuidString.prefix(5)) " +
            "generation=\(authority.ownershipGeneration) serial=\(authority.instanceSerial)"
        )
#endif
    }

    /// Wakes parked candidates after an owner vacancy. The surface owns the
    /// wake phase: one scheduled drain observes the latest retry registry for
    /// one lifecycle generation, newest host first so a single claim wins and
    /// the rest are rejected against it. Common run-loop modes are used because
    /// owners vacate mid divider-drag, where a default-mode block waits for
    /// mouse-up. Deferred a turn so no retry mutates the lease inside the dying
    /// host's dismantle.
    private func notifyPortalHostVacated(vacatedHostId: ObjectIdentifier, instanceSerial: UInt64) {
        if portalHostVacancyRetries[vacatedHostId]?.instanceSerial == instanceSerial {
            portalHostVacancyRetries.removeValue(forKey: vacatedHostId)
        }
        guard canAcceptPortalBinding(expectedSurfaceId: nil, expectedGeneration: nil) else {
            clearPortalHostVacancyRetries()
            return
        }
        let scheduledGeneration = portalLifecycleGeneration
        guard portalHostVacancyRetries.values.contains(where: { $0.generation == scheduledGeneration }) else { return }
        guard portalHostVacancyWakeGeneration != scheduledGeneration else { return }
        portalHostVacancyWakeGeneration = scheduledGeneration
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            guard self.portalHostVacancyWakeGeneration == scheduledGeneration else { return }
            self.portalHostVacancyWakeGeneration = nil
            guard self.canAcceptPortalBinding(expectedSurfaceId: self.id, expectedGeneration: scheduledGeneration) else {
                self.portalHostVacancyRetries = self.portalHostVacancyRetries.filter {
                    $0.value.generation != scheduledGeneration
                }
                return
            }
            let retries = self.portalHostVacancyRetries.values
                .filter { $0.generation == scheduledGeneration }
                .sorted { $0.instanceSerial > $1.instanceSerial }
                .map(\.retry)
            for retry in retries { retry() }
        }
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
        let leasePolicy = PortalHostLeasePolicy()
        let next = PortalHostLease(
            hostId: hostId,
            paneId: paneId.id,
            instanceSerial: instanceSerial,
            inWindow: inWindow,
            area: leasePolicy.area(for: bounds)
        )

        // Owner identity is host AND creation serial: ObjectIdentifier values
        // are reused after dealloc, and a new incarnation at a recycled address
        // must not inherit the old owner's standing (or bypass
        // allowsAuthorityAcquisition through it).
        let alreadyOwnsLease = activePortalHostLease.map {
            $0.hostId == hostId && $0.instanceSerial == instanceSerial
        } ?? false
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

#if DEBUG
        func logAuthorityRefusal() {
            logDebugEvent(
                "terminal.portal.host.skip surface=\(id.uuidString.prefix(5)) " +
                "reason=\(reason) host=\(hostId) pane=\(paneId.id.uuidString.prefix(5)) " +
                "cause=authorityRefused authorityHost=\(portalHostAuthority.map { String(describing: $0.hostId) } ?? "nil") " +
                "authorityGeneration=\(portalHostAuthority?.ownershipGeneration ?? 0) " +
                "authoritySerial=\(portalHostAuthority?.instanceSerial ?? 0) " +
                "claimGeneration=\(ownershipGeneration) claimSerial=\(instanceSerial)"
            )
        }
#else
        func logAuthorityRefusal() {}
#endif

        if let current = activePortalHostLease {
            if current.hostId == hostId, current.instanceSerial == instanceSerial {
                guard reservePortalHostAuthority(
                    hostId: hostId,
                    paneId: paneId,
                    instanceSerial: instanceSerial,
                    ownershipGeneration: ownershipGeneration
                ) else {
                    logAuthorityRefusal()
                    return false
                }
                activePortalHostLease = next
                return true
            }

            // During split churn SwiftUI can briefly keep the old host alive while the new
            // host for the same pane is already in the window. Prefer the newer live host
            // immediately so the surface moves with the pane instead of waiting for a later
            // update from unrelated focus/layout work.
            let newerSamePaneHostReady =
                current.paneId == paneId.id &&
                next.instanceSerial > current.instanceSerial
            let newerModelOwnerReady =
                ownershipGeneration > (portalHostAuthority?.ownershipGeneration ?? 0)
            let shouldReplace = leasePolicy.shouldReplace(
                current: current,
                with: next,
                allowsSamePaneReplacement: newerSamePaneHostReady || newerModelOwnerReady
            )

            if shouldReplace {
                guard reservePortalHostAuthority(
                    hostId: hostId,
                    paneId: paneId,
                    instanceSerial: instanceSerial,
                    ownershipGeneration: ownershipGeneration
                ) else {
                    logAuthorityRefusal()
                    return false
                }
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
                "ownerArea=\(String(format: "%.1f", current.area)) " +
                "cause=\(leasePolicy.isUsable(next) ? "ownerPreferred" : "detachedOrTiny")"
            )
#endif
            return false
        }

        guard reservePortalHostAuthority(
            hostId: hostId,
            paneId: paneId,
            instanceSerial: instanceSerial,
            ownershipGeneration: ownershipGeneration
        ) else {
            logAuthorityRefusal()
            return false
        }
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
    public func releasePortalHostIfOwned(
        hostId: ObjectIdentifier,
        instanceSerial: UInt64,
        reason: String
    ) {
        guard let current = activePortalHostLease,
              current.hostId == hostId,
              current.instanceSerial == instanceSerial else { return }
        activePortalHostLease = nil
        clearPortalHostAuthorityIfHeld(by: hostId, instanceSerial: current.instanceSerial)
        notifyPortalHostVacated(vacatedHostId: hostId, instanceSerial: current.instanceSerial)
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
