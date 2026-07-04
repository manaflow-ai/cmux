internal import CMUXMobileCore
internal import CmuxMobileIrohTransport

/// Pure glue between stored Mac routes and ``CmxEndpointPinGate``.
struct MobileIrohPinPolicy: Sendable {
    private let gate: CmxEndpointPinGate

    init(gate: CmxEndpointPinGate = CmxEndpointPinGate()) {
        self.gate = gate
    }

    func classification(
        for route: CmxAttachRoute,
        pinnedEndpointID: String?
    ) -> MobileIrohPinRouteClassification {
        guard route.kind == .iroh,
              case let .peer(id, _, _, _) = route.endpoint else {
            return .dialable
        }
        switch gate.evaluate(dialedEndpointID: id, pinnedEndpointID: pinnedEndpointID) {
        case .trusted:
            return .dialable
        case .firstTrust(let id):
            return .firstTrust(id)
        case let .mismatch(pinned, dialed):
            return .mismatch(pinned: pinned, advertised: dialed)
        }
    }

    func tokenBearingDialableRoutes(
        _ routes: [CmxAttachRoute],
        pinnedEndpointID: String?
    ) -> [CmxAttachRoute] {
        routes.filter {
            classification(for: $0, pinnedEndpointID: pinnedEndpointID).allowsTokenBearingDial
        }
    }

    func hasMismatch(
        routes: [CmxAttachRoute],
        pinnedEndpointID: String?
    ) -> Bool {
        routes.contains {
            if case .mismatch = classification(for: $0, pinnedEndpointID: pinnedEndpointID) {
                return true
            }
            return false
        }
    }

    func firstIrohEndpointID(in routes: [CmxAttachRoute]) -> String? {
        routes.sorted(by: routeSortsBefore).compactMap(\.irohEndpointID).first
    }

    func endpointIDToPinAfterSuccessfulDial(
        route: CmxAttachRoute,
        pinnedEndpointID: String?
    ) -> String? {
        guard case let .firstTrust(id) = classification(for: route, pinnedEndpointID: pinnedEndpointID) else {
            return nil
        }
        return id
    }

    private func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }
}
