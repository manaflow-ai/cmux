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
        routes(port: port, tailscaleHosts: Self.tailscaleRouteHosts())
    }

    func routes(port: Int, tailscaleHosts: [String]) -> MobileHostRouteSnapshot {
        var resolved: [CmxAttachRoute] = []

        if let debugRoute = try? CmxAttachRoute(
            id: CmxAttachTransportKind.debugLoopback.rawValue,
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            priority: 0
        ) {
            resolved.append(debugRoute)
        }

        for (index, tailscaleHost) in tailscaleHosts.enumerated() {
            let id = index == 0
                ? CmxAttachTransportKind.tailscale.rawValue
                : "\(CmxAttachTransportKind.tailscale.rawValue)_\(index + 1)"
            if let tailscaleRoute = try? CmxAttachRoute(
                id: id,
                kind: .tailscale,
                endpoint: .hostPort(host: tailscaleHost, port: port),
                priority: 10 + (index * 10)
            ) {
                resolved.append(tailscaleRoute)
            }
        }

        return MobileHostRouteSnapshot(routes: resolved)
    }

    private struct TailscaleAddressCandidate {
        let interfaceName: String
        let address: String
        let dnsName: String?
    }

    private static func tailscaleRouteHosts() -> [String] {
        guard let candidate = preferredTailscaleAddressCandidate() else {
            return []
        }

        var hosts: [String] = []
        if let dnsName = candidate.dnsName {
            hosts.append(dnsName)
        }
        hosts.append(candidate.address)

        var seen = Set<String>()
        return hosts.filter { host in
            let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                return false
            }
            seen.insert(normalized)
            return true
        }
    }

    private static func preferredTailscaleAddressCandidate() -> TailscaleAddressCandidate? {
        let candidates = tailscaleAddressCandidates()
        if let match = candidates.first(where: { isTailscaleDNSName($0.dnsName) }) {
            return match
        }
        return candidates.first
    }

    private static func tailscaleAddressCandidates() -> [TailscaleAddressCandidate] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var tailscaleInterfaceNames = Set<String>()
        var cgnatCandidates: [TailscaleAddressCandidate] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let nameCString = current.pointee.ifa_name else {
                continue
            }
            let interfaceName = String(cString: nameCString)
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else {
                continue
            }
            guard let address = current.pointee.ifa_addr,
                  let candidate = numericHost(for: address) else {
                continue
            }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                if isTailscaleCGNAT(candidate) {
                    cgnatCandidates.append(
                        TailscaleAddressCandidate(
                            interfaceName: interfaceName,
                            address: candidate,
                            dnsName: reverseDNSHost(for: address)
                        )
                    )
                }
            case AF_INET6:
                if isTailscaleIPv6ULA(candidate) || isTailscaleInterfaceName(interfaceName) {
                    tailscaleInterfaceNames.insert(interfaceName)
                }
            default:
                break
            }
        }

        let confirmedCandidates = cgnatCandidates.filter { candidate in
            tailscaleInterfaceNames.contains(candidate.interfaceName) ||
                isTailscaleInterfaceName(candidate.interfaceName)
        }
        return confirmedCandidates.isEmpty ? cgnatCandidates : confirmedCandidates
    }

    private static func numericHost(for address: UnsafeMutablePointer<sockaddr>) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET, AF_INET6:
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
            return result == 0 ? String(cString: host) : nil
        default:
            return nil
        }
    }

    private static func reverseDNSHost(for address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NAMEREQD
        )
        guard result == 0 else {
            return nil
        }
        let name = String(cString: host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return isTailscaleDNSName(name) ? name : nil
    }

    private static func isTailscaleCGNAT(_ ipAddress: String) -> Bool {
        let octets = ipAddress.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    private static func isTailscaleIPv6ULA(_ ipAddress: String) -> Bool {
        ipAddress.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    private static func isTailscaleInterfaceName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("tailscale")
    }

    private static func isTailscaleDNSName(_ name: String?) -> Bool {
        guard let name else {
            return false
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasSuffix(".ts.net")
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
