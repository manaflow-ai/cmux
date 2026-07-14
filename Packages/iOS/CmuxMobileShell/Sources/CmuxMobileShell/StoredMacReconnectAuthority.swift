import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

@MainActor
struct StoredMacReconnectAuthority {
    let macDeviceID: String
    let storedMac: MobilePairedMac?
    private let fallbackDisplayName: String

    init(
        ticket: CmxAttachTicket,
        sourceMac: MobilePairedMac,
        knownMacs: [MobilePairedMac],
        routeDisplayName: String
    ) {
        let authoritativeMacDeviceID = ticket.foregroundMacID(hint: sourceMac.macDeviceID)
        macDeviceID = authoritativeMacDeviceID
        storedMac = knownMacs.first {
            MobileMacInstanceTagAuthority.authenticatedDeviceMatches(
                reportedDeviceID: $0.macDeviceID,
                expectedDeviceID: authoritativeMacDeviceID
            )
        }
        fallbackDisplayName = storedMac?.displayName
            ?? ticket.macDisplayName
            ?? routeDisplayName
    }

    func resolve(
        status: MobileHostStatusResponse?
    ) -> (accepted: Bool, instanceTag: String?) {
        let reportedDeviceID = MobileMacInstanceTagAuthority.normalized(status?.macDeviceID)
        if let reportedDeviceID,
           !MobileMacInstanceTagAuthority.authenticatedDeviceMatches(
               reportedDeviceID: reportedDeviceID,
               expectedDeviceID: macDeviceID
           ) {
            return (false, nil)
        }
        let expectation = MobileMacInstanceTagAuthority.expectation(
            storedInstanceTag: storedMac?.instanceTag
        )
        if case .preserve = expectation, reportedDeviceID == nil {
            return (false, nil)
        }
        guard case .accept(let resolved) = MobileMacInstanceTagAuthority.resolve(
            expectation: expectation,
            reportedInstanceTag: status?.macInstanceTag
        ) else {
            return (false, nil)
        }
        return (true, resolved)
    }

    func displayName(status: MobileHostStatusResponse?) -> String {
        status?.macDisplayName ?? fallbackDisplayName
    }

    func registryMac(
        ticket: CmxAttachTicket,
        status: MobileHostStatusResponse?,
        scope: MobileShellScopeSnapshot,
        resolvedInstanceTag: String?
    ) -> MobilePairedMac {
        var mac = storedMac ?? MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: displayName(status: status),
            routes: ticket.routes,
            createdAt: Date(),
            lastSeenAt: Date(),
            isActive: true,
            stackUserID: scope.userID,
            teamID: scope.teamID,
            instanceTag: resolvedInstanceTag
        )
        mac.macDeviceID = macDeviceID
        mac.displayName = displayName(status: status)
        let authorityUnchanged = resolvedInstanceTag == mac.instanceTag
        mac.routes = authorityUnchanged
            && ticket.routes.count == 1
            && !mac.routes.isEmpty
            ? MobileShellComposite.mergedReconnectRoutes(
                ticketRoutes: ticket.routes,
                storedRoutes: mac.routes
            )
            : ticket.routes
        mac.instanceTag = resolvedInstanceTag
        mac.isActive = true
        mac.stackUserID = scope.userID
        mac.teamID = scope.teamID
        return mac
    }
}
