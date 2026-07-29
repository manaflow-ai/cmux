internal import CMUXMobileCore
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
                host: host.lowercased(),
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
          let host = components.host?.lowercased() else {
        return value
            .split(separator: "#", maxSplits: 1)[0]
            .split(separator: "?", maxSplits: 1)[0]
            .lowercased()
    }
    let port = components.port.map { ":\($0)" } ?? ""
    return "\(scheme)://\(host)\(port)\(components.percentEncodedPath)"
}
