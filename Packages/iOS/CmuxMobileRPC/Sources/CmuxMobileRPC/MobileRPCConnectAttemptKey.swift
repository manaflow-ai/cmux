internal import CMUXMobileCore
import Darwin
import Foundation

/// In-memory identity for one physical peer route.
///
/// Diagnostic route descriptions intentionally redact peer identities and
/// path hints change as network reachability changes. Admission instead keys
/// Iroh routes by the authenticated endpoint identity and other routes by a
/// stable physical endpoint boundary. Cleanup debt therefore survives hint,
/// credential, and anonymous ticket identity changes.
struct MobileRPCConnectAttemptKey: Hashable, Sendable {
    let endpointIdentity: MobileRPCConnectEndpointIdentity

    init(route: CmxAttachRoute) {
        switch route.endpoint {
        case let .peer(identity, _):
            endpointIdentity = .iroh(endpointID: identity.endpointID)
        case let .hostPort(host, port):
            endpointIdentity = .hostPort(
                kind: route.kind.rawValue,
                host: canonicalHostIdentity(host),
                port: port
            )
        case let .url(value):
            endpointIdentity = .url(
                kind: route.kind.rawValue,
                endpoint: stableURLIdentity(value)
            )
        }
    }
}

private func stableURLIdentity(_ value: String) -> String {
    guard let components = URLComponents(string: value),
          let scheme = components.scheme?.lowercased(),
          let host = components.host else {
        return value
            .split(separator: "#", maxSplits: 1)[0]
            .split(separator: "?", maxSplits: 1)[0]
            .lowercased()
    }
    let port = (components.port ?? defaultPort(for: scheme))
        .map(String.init) ?? ""
    return """
        scheme=\(scheme);host=\(canonicalHostIdentity(host));\
        port=\(port);path=\(components.percentEncodedPath)
        """
}

private func defaultPort(for scheme: String) -> Int? {
    switch scheme {
    case "http", "ws":
        80
    case "https", "wss":
        443
    default:
        nil
    }
}

private func canonicalHostIdentity(_ value: String) -> String {
    var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.hasPrefix("["), host.hasSuffix("]") {
        host.removeFirst()
        host.removeLast()
    }
    let addressAndZone = host.split(
        separator: "%",
        maxSplits: 1,
        omittingEmptySubsequences: false
    )
    let address = String(addressAndZone[0])
    let zone = addressAndZone.count == 2
        ? "%\(addressAndZone[1].lowercased())"
        : ""
    if let canonical = canonicalIPv4Address(address)
        ?? canonicalIPv6Address(address) {
        return canonical + zone
    }
    var dnsHost = address.lowercased()
    if dnsHost.hasSuffix(".") {
        dnsHost.removeLast()
    }
    return dnsHost
}

private func canonicalIPv4Address(_ value: String) -> String? {
    var address = in_addr()
    guard value.withCString({
        inet_aton($0, &address)
    }) != 0 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    return buffer.withUnsafeMutableBufferPointer { output in
        guard inet_ntop(
            AF_INET,
            &address,
            output.baseAddress,
            socklen_t(output.count)
        ) != nil else {
            return nil
        }
        return String(cString: output.baseAddress!)
    }
}

private func canonicalIPv6Address(_ value: String) -> String? {
    var address = in6_addr()
    guard value.withCString({
        inet_pton(AF_INET6, $0, &address)
    }) == 1 else {
        return nil
    }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    return buffer.withUnsafeMutableBufferPointer { output in
        guard inet_ntop(
            AF_INET6,
            &address,
            output.baseAddress,
            socklen_t(output.count)
        ) != nil else {
            return nil
        }
        return String(cString: output.baseAddress!)
    }
}
