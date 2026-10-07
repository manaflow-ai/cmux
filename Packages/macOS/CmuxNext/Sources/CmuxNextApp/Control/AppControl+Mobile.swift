import CmuxNextControl
import CmuxNextMobile
import CMUXMobileCore
import CmuxNextSettings
import Foundation

// Control verbs the iOS dogfood launcher (scripts/mobile-dev-launch.sh)
// needs: `mobile.attach_ticket.create` mints a Mac-scoped attach URL, and
// usable phone connections are published as `mobile.rpc.ready` events on
// `events.stream` (payload: connection_id, client_id, stream_id, transport,
// workspace_count).
extension AppControl {
    func registerMobileMethods(_ services: AppServices) {
        guard let router = service?.router else { return }
        let events = router.events
        services.mobile.readiness.install { session in
            events.publish(name: "mobile.rpc.ready", category: "mobile", source: "mobile.host", payload: [
                "connection_id": .string(session.connectionID), "client_id": .string(session.clientID),
                "stream_id": .string(session.streamID), "transport": .string(session.transport),
                "workspace_count": JSONValue(session.workspaceCount),
            ])
        }
        let tag = services.environment.launch.tag
        router.register([
            .mainActor("mobile.attach_ticket.create") { call in
                let request = try Self.ticketRequest(call.params)
                guard let host = services.mobile.host else {
                    throw ControlError(code: "unavailable", message: "Mobile host routes are not available yet",
                                       data: ["reason": "phone access starts after Cloud sign-in"])
                }
                let scheme = Self.pairingScheme(tag: tag)
                return .followUp {
                    do {
                        let payload = try await host.attachTicket(ttl: request.ttl, target: request.target, scheme: scheme)
                        return try JSONValue.parse(try payload.json())
                    } catch let failure as MobileIrxHost.TicketFailure {
                        throw ControlError(code: "unavailable", message: failure.description)
                    }
                }
            },
        ])
    }

    struct TicketRequest {
        var ttl: TimeInterval
        var target: MobileAttachTicket.Target
    }

    static func ticketRequest(_ params: [String: JSONValue]) throws -> TicketRequest {
        let ttl = params["ttl_seconds"]?.doubleValue ?? 600
        guard ttl.isFinite, ttl > 0 else { throw ControlError.invalidParams("ttl_seconds must be a positive number") }
        if let scope = params["scope"]?.stringValue, scope != "mac" {
            throw ControlError.invalidParams("cmux-next mints Mac-scoped tickets only (scope \"mac\")")
        }
        let raw = params["target"]?.stringValue ?? MobileAttachTicket.Target.physicalDevice.rawValue
        guard let target = MobileAttachTicket.Target(wireValue: raw) else {
            throw ControlError.invalidParams("target must be physical_device or simulator_injection")
        }
        return TicketRequest(ttl: ttl, target: target)
    }

    /// The same-tag iOS build's pairing scheme (`dev.cmux.ios.<tag>`), or an
    /// explicit `CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER`.
    static func pairingScheme(tag: String?) -> CmxPairingURLScheme? {
        var environment: [String: String] = [:]
        if let tag { environment["CMUX_TAG"] = tag }
        if let explicit = ProcessInfo.processInfo.environment["CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER"] {
            environment["CMUX_IOS_PAIRING_BUNDLE_IDENTIFIER"] = explicit
        }
        return CmxPairingURLSchemeResolver(bundle: .main, environment: environment).resolved
    }
}
