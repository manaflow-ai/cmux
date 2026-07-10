import CMUXMobileCore
import Foundation

struct MobileHostIrohRoute {
    static let priority = 5

    static func route(from json: String) -> CmxAttachRoute? {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(CmxAttachRoute.self, from: data) else {
            return nil
        }
        return normalized(decoded)
    }

    static func normalized(_ route: CmxAttachRoute) -> CmxAttachRoute? {
        guard route.kind == .iroh,
              case .peer = route.endpoint else {
            return nil
        }
        return try? CmxAttachRoute(
            id: CmxAttachTransportKind.iroh.rawValue,
            kind: .iroh,
            endpoint: route.endpoint,
            priority: priority
        )
    }

    static func shortEndpointID(_ endpointID: String) -> String {
        let trimmed = endpointID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        return String(trimmed.prefix(12))
    }

    static func relayHost(_ relayURL: String?) -> String? {
        guard let relayURL = relayURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relayURL.isEmpty else {
            return nil
        }
        return URL(string: relayURL)?.host ?? relayURL
    }
}
