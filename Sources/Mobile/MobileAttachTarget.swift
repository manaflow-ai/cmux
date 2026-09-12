import CMUXMobileCore
import CmuxMobilePairing

/// App-target compatibility facade for the package-owned route planner.
///
/// Ticket issuance and its error vocabulary stay in the host app; route
/// selection itself lives in ``CmxMobileAttachRoutePlanner`` so it is testable
/// without launching the app.
enum MobileAttachTarget: String, Sendable {
    case ticketOnly = "ticket_only"
    case simulatorInjection = "simulator_injection"
    case physicalDevice = "physical_device"

    init?(wireValue: String) {
        self.init(rawValue: wireValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    func selectRoutes(from routes: [CmxAttachRoute]) throws -> [CmxAttachRoute] {
        do {
            return try CmxMobileAttachRoutePlanner().selectRoutes(
                for: CmxMobileAttachTarget(rawValue: rawValue),
                from: routes
            )
        } catch CmxMobileAttachRoutePlanningError.noRoutes {
            throw MobileAttachTicketStoreError.noRoutes
        } catch CmxMobileAttachRoutePlanningError.routeUnavailable {
            throw MobileAttachTicketStoreError.routeUnavailable
        } catch {
            throw MobileAttachTicketStoreError.invalidAttachURL
        }
    }

}

extension Optional where Wrapped == MobileAttachTarget {
    /// A missing target preserves the legacy full-route ticket contract.
    func selectRoutes(from routes: [CmxAttachRoute]) throws -> [CmxAttachRoute] {
        guard let target = self else {
            guard !routes.isEmpty else { throw MobileAttachTicketStoreError.noRoutes }
            return routes
        }
        return try target.selectRoutes(from: routes)
    }
}
