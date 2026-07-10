import CMUXMobileCore
import Foundation

extension MobilePairedMacStore {
    static func firstIrohEndpointID(in routes: [CmxAttachRoute]) -> String? {
        for route in routes.sorted(by: { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.id < rhs.id
        }) where route.kind == .iroh {
            if case let .peer(id, _, _, _) = route.endpoint {
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
