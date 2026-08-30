import CMUXMobileCore
import CmuxIrxTransport
import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    /// Maps the host's runtime status into the Foundation-only Settings value.
    nonisolated static func mobilePairingSnapshot(
        from status: MobileHostServiceStatus,
        now: Date = Date()
    ) -> MobilePairingStatusSnapshot {
        var seenEndpoints = Set<String>()
        let routes = status.routes.flatMap { route -> [MobilePairingRoute] in
            switch route.endpoint {
            case let .hostPort(host, port):
                return [MobilePairingRoute(
                    id: route.id,
                    kindLabel: routeKindLabel(route.kind),
                    host: host,
                    port: port
                )]
            case let .peer(_, pathHints):
                return pathHints.compactMap { hint in
                    guard hint.kind == .directAddress,
                          hint.isUsable(at: now),
                          seenEndpoints.insert(hint.value).inserted,
                          let address = splitSocketAddress(hint.value) else { return nil }
                    return MobilePairingRoute(
                        id: "\(route.id):\(hint.value)",
                        kindLabel: routeKindLabel(route.kind),
                        host: address.host,
                        port: address.port
                    )
                }
            case .url:
                return []
            }
        }
        return MobilePairingStatusSnapshot(
            isRunning: status.isRunning,
            configuredPort: status.configuredPort,
            boundPort: status.port,
            usesEphemeralFallback: status.usesEphemeralFallback,
            activeConnectionCount: status.activeConnectionCount,
            routes: routes,
            irohStatus: mobilePairingStatus(state: status.irxActivationState),
            irohBrokerOperation: status.irxBrokerFailure?.operation.rawValue,
            irohBrokerErrorCode: status.irxBrokerFailure?.errorCode
        )
    }

    nonisolated static func mobilePairingStatus(
        state: IrxHostActivationState
    ) -> MobilePairingIrohStatus {
        switch state {
        case .inactive: .inactive
        case .activating: .starting
        case .active: .active
        case .retrying: .retrying
        case .failed: .failed
        case .reauthenticationRequired: .reauthenticationRequired
        }
    }

    /// Splits an Iroh direct-address hint into a displayable host and port.
    nonisolated static func splitSocketAddress(
        _ value: String
    ) -> (host: String, port: Int)? {
        let hostPart: Substring
        let portPart: Substring
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else { return nil }
            hostPart = value[value.index(after: value.startIndex)..<closing]
            let remainder = value[value.index(after: closing)...]
            guard remainder.first == ":" else { return nil }
            portPart = remainder.dropFirst()
        } else {
            guard let separator = value.lastIndex(of: ":"),
                  !value[..<separator].contains(":") else { return nil }
            hostPart = value[..<separator]
            portPart = value[value.index(after: separator)...]
        }
        guard !hostPart.isEmpty,
              let port = Int(portPart),
              (1 ... 65535).contains(port) else { return nil }
        return (String(hostPart), port)
    }

    private nonisolated static func routeKindLabel(
        _ kind: CmxAttachTransportKind
    ) -> String {
        switch kind {
        case .tailscale:
            String(localized: "settings.mobile.route.tailscale", defaultValue: "Tailscale")
        case .debugLoopback:
            String(localized: "settings.mobile.route.loopback", defaultValue: "Loopback")
        case .iroh:
            String(localized: "settings.mobile.route.iroh", defaultValue: "Iroh")
        case .websocket:
            String(localized: "settings.mobile.route.websocket", defaultValue: "WebSocket")
        }
    }
}
