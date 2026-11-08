import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import Foundation

/// Foreground ownership published before its first transport suspension.
/// Background aggregation consults this reservation so a previously selected
/// control candidate cannot admit a second session on the foreground route.
struct ForegroundConnectionAttemptReservation {
    let id: UUID
    let requestedMacDeviceID: String?
    let instanceTagExpectation: MobileMacInstanceTagExpectation
    let routes: [CmxAttachRoute]

    func conflicts(with mac: MobilePairedMac) -> Bool {
        if targetsSamePairing(as: mac) {
            return true
        }
        return mac.routes.contains { storedRoute in
            routes.contains { foregroundRoute in
                MobileCoreRPCClient.routesSharePhysicalTransport(
                    storedRoute,
                    foregroundRoute
                )
            }
        }
    }

    private func targetsSamePairing(as mac: MobilePairedMac) -> Bool {
        guard let requestedMacDeviceID,
              cmxCanonicalDeviceID(requestedMacDeviceID)
                  == cmxCanonicalDeviceID(mac.macDeviceID) else {
            return false
        }
        switch instanceTagExpectation {
        case .adopt:
            // Until authentication reports a tag, this attempt can own any
            // saved row for the requested logical Mac.
            return true
        case .preserve(let tag), .require(let tag):
            // A saved row is an exact owner. A legacy untagged row is only
            // compatible with another untagged attempt, never with Stable or
            // Nightly merely because the physical device id matches.
            return CmxMacAppInstanceIdentity(
                macDeviceID: requestedMacDeviceID,
                instanceTag: tag
            ).id == CmxMacAppInstanceIdentity(
                macDeviceID: mac.macDeviceID,
                instanceTag: mac.instanceTag
            ).id
        }
    }
}
