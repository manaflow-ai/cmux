import Foundation
import CoreGraphics

struct PortalHostLease: Equatable {
    let hostId: ObjectIdentifier
    let contextId: UUID?
    let inWindow: Bool
    let area: CGFloat
}

struct PortalHostLeaseClaimOutcome {
    let accepted: Bool
    let activeLease: PortalHostLease?
    let replacedLease: PortalHostLease?
    let didAcquireOwnership: Bool
    let forcedDistinctReplacement: Bool
    let blockedByLock: Bool
}

struct PortalHostLeasingState {
    private struct PortalHostLock: Equatable {
        let hostId: ObjectIdentifier
        let contextId: UUID?
    }

    private static let areaThreshold: CGFloat = 4
    private static let replacementAreaGainRatio: CGFloat = 1.2

    private(set) var activeLease: PortalHostLease?
    private var pendingDistinctReplacementContextId: UUID?
    private var lockedLease: PortalHostLock?

    static func leaseArea(for bounds: CGRect) -> CGFloat {
        max(0, bounds.width) * max(0, bounds.height)
    }

    static func isUsable(_ lease: PortalHostLease) -> Bool {
        lease.inWindow && lease.area > areaThreshold
    }

    mutating func prepareForNextDistinctReplacement(contextId: UUID) {
        pendingDistinctReplacementContextId = contextId
        if lockedLease?.contextId == contextId {
            lockedLease = nil
        }
    }

    mutating func claim(
        hostId: ObjectIdentifier,
        contextId: UUID? = nil,
        inWindow: Bool,
        bounds: CGRect
    ) -> PortalHostLeaseClaimOutcome {
        let next = PortalHostLease(
            hostId: hostId,
            contextId: contextId,
            inWindow: inWindow,
            area: Self.leaseArea(for: bounds)
        )

        if let current = activeLease {
            if let lockedLease,
               (lockedLease.hostId != current.hostId || lockedLease.contextId != current.contextId) {
                self.lockedLease = nil
            }

            if current.hostId == hostId {
                let currentUsable = Self.isUsable(current)
                let nextUsable = Self.isUsable(next)
                if currentUsable && !nextUsable {
                    return PortalHostLeaseClaimOutcome(
                        accepted: true,
                        activeLease: current,
                        replacedLease: nil,
                        didAcquireOwnership: false,
                        forcedDistinctReplacement: false,
                        blockedByLock: false
                    )
                }

                activeLease = next
                return PortalHostLeaseClaimOutcome(
                    accepted: true,
                    activeLease: next,
                    replacedLease: nil,
                    didAcquireOwnership: false,
                    forcedDistinctReplacement: false,
                    blockedByLock: false
                )
            }

            let currentUsable = Self.isUsable(current)
            let nextUsable = Self.isUsable(next)
            let sharedContextId = current.contextId.flatMap { currentContextId in
                next.contextId == currentContextId ? currentContextId : nil
            }
            let isSameContextReplacement = sharedContextId != nil
            let shouldForceDistinctReplacement =
                isSameContextReplacement &&
                pendingDistinctReplacementContextId == sharedContextId &&
                inWindow

            if shouldForceDistinctReplacement {
                activeLease = next
                pendingDistinctReplacementContextId = nil
                lockedLease = PortalHostLock(hostId: hostId, contextId: next.contextId)
                return PortalHostLeaseClaimOutcome(
                    accepted: true,
                    activeLease: next,
                    replacedLease: current,
                    didAcquireOwnership: true,
                    forcedDistinctReplacement: true,
                    blockedByLock: false
                )
            }

            let lockBlocksSameContextReplacement =
                isSameContextReplacement &&
                currentUsable &&
                lockedLease?.hostId == current.hostId &&
                lockedLease?.contextId == current.contextId
            let shouldReplace =
                current.contextId != next.contextId ||
                !currentUsable ||
                (
                    !lockBlocksSameContextReplacement &&
                    nextUsable &&
                    next.area > (current.area * Self.replacementAreaGainRatio)
                )

            if shouldReplace {
                if lockedLease?.hostId == current.hostId &&
                    lockedLease?.contextId == current.contextId {
                    lockedLease = nil
                }
                activeLease = next
                return PortalHostLeaseClaimOutcome(
                    accepted: true,
                    activeLease: next,
                    replacedLease: current,
                    didAcquireOwnership: true,
                    forcedDistinctReplacement: false,
                    blockedByLock: false
                )
            }

            return PortalHostLeaseClaimOutcome(
                accepted: false,
                activeLease: current,
                replacedLease: nil,
                didAcquireOwnership: false,
                forcedDistinctReplacement: false,
                blockedByLock: lockBlocksSameContextReplacement
            )
        }

        activeLease = next
        return PortalHostLeaseClaimOutcome(
            accepted: true,
            activeLease: next,
            replacedLease: nil,
            didAcquireOwnership: true,
            forcedDistinctReplacement: false,
            blockedByLock: false
        )
    }

    mutating func releaseIfOwned(hostId: ObjectIdentifier) -> PortalHostLease? {
        guard let current = activeLease, current.hostId == hostId else { return nil }
        activeLease = nil
        if lockedLease?.hostId == hostId {
            lockedLease = nil
        }
        return current
    }

    func owns(hostId: ObjectIdentifier) -> Bool {
        activeLease?.hostId == hostId
    }
}
