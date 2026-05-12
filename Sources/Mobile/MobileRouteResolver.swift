import CMUXMobileCore
import Darwin
import Foundation

struct MobileHostRouteSnapshot: Sendable {
    let routes: [CmxAttachRoute]

    var payload: [[String: Any]] {
        routes.map(\.mobileHostJSONObject)
    }
}

struct MobileRouteResolver: Sendable {
    func routes(port: Int) -> MobileHostRouteSnapshot {
        var resolved: [CmxAttachRoute] = []

        if let debugRoute = try? CmxAttachRoute(
            id: CmxAttachTransportKind.debugLoopback.rawValue,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        ) {
            resolved.append(debugRoute)
        }

        if let tailscaleHost = Self.tailscaleIPv4Address(),
           let tailscaleRoute = try? CmxAttachRoute(
               id: CmxAttachTransportKind.tailscale.rawValue,
               kind: .tailscale,
               endpoint: .hostPort(host: tailscaleHost, port: port),
               priority: 10
           ) {
            resolved.append(tailscaleRoute)
        }

        return MobileHostRouteSnapshot(routes: resolved)
    }

    private static func tailscaleIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                continue
            }

            let candidate = String(cString: host)
            if isTailscaleCGNAT(candidate) {
                return candidate
            }
        }

        return nil
    }

    private static func isTailscaleCGNAT(_ ipAddress: String) -> Bool {
        let octets = ipAddress.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }
}

extension CmxAttachRoute {
    var mobileHostJSONObject: [String: Any] {
        var endpointPayload: [String: Any] = [:]
        switch endpoint {
        case let .hostPort(host, port):
            endpointPayload = [
                "type": "host_port",
                "host": host,
                "port": port
            ]
        case let .peer(id, relayHint, directAddrs, relayURL):
            endpointPayload = [
                "type": "peer",
                "id": id,
                "relay_hint": relayHint ?? NSNull(),
            ]
            if !directAddrs.isEmpty {
                endpointPayload["direct_addrs"] = directAddrs
            }
            if let relayURL {
                endpointPayload["relay_url"] = relayURL
            }
        case let .url(url):
            endpointPayload = [
                "type": "url",
                "url": url
            ]
        }

        return [
            "id": id,
            "kind": kind.rawValue,
            "endpoint": endpointPayload,
            "priority": priority
        ]
    }
}
