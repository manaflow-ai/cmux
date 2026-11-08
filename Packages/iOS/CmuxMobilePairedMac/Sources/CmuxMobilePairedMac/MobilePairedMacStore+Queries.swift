import CMUXMobileCore
import Foundation

extension Collection where Element == MobilePairedMac {
    /// Resolves the newest stored row for a physical Mac and optional app instance.
    ///
    /// A missing instance tag is a device-level request and therefore matches
    /// every saved app instance on that physical Mac. A supplied tag remains an
    /// exact app-instance match. Results are ordered by ``MobilePairedMac/lastSeenAt``
    /// with a stable pairing-id tie-breaker so device-only callers make the same
    /// choice regardless of the store implementation's row ordering.
    /// Device-level mutation APIs keep their separate fail-closed contracts.
    /// - Parameters:
    ///   - macDeviceID: Stable identifier of the physical Mac to resolve.
    ///   - instanceTag: Exact app-instance tag, or `nil` for device-level lookup.
    /// - Returns: The newest matching row, or `nil` when no row matches.
    public func mostRecentPairedMac(
        macDeviceID: String,
        instanceTag: String?
    ) -> MobilePairedMac? {
        let requestedIdentity = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        var newestMatch: MobilePairedMac?
        for candidate in self {
            let candidateIdentity = CmxMacAppInstanceIdentity(
                macDeviceID: candidate.macDeviceID,
                instanceTag: candidate.instanceTag
            )
            guard candidateIdentity.macDeviceID == requestedIdentity.macDeviceID else {
                continue
            }
            if let requestedTag = requestedIdentity.instanceTag,
               candidateIdentity.instanceTag != requestedTag {
                continue
            }
            guard let current = newestMatch else {
                newestMatch = candidate
                continue
            }
            let candidateIsNewer: Bool
            if candidate.lastSeenAt != current.lastSeenAt {
                candidateIsNewer = candidate.lastSeenAt > current.lastSeenAt
            } else if candidate.id != current.id {
                candidateIsNewer = candidate.id < current.id
            } else {
                candidateIsNewer = (candidate.teamID ?? "") < (current.teamID ?? "")
            }
            if candidateIsNewer {
                newestMatch = candidate
            }
        }
        return newestMatch
    }
}
