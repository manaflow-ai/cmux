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
    enum EndpointIdentity: Hashable, Sendable {
        case iroh(endpointID: String)
        case hostPort(kind: String, host: String, port: Int)
        case url(kind: String, endpoint: String)
    }

    let endpointIdentity: EndpointIdentity

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
            // URL query parameters may contain rotating credentials and
            // fragments are client-local. Keep the scheme, authority, and path
            // so unrelated WebSocket services do not share cleanup debt.
            endpointIdentity = .url(
                kind: route.kind.rawValue,
                endpoint: Self.stableURLIdentity(value)
            )
        }
    }

    private static func stableURLIdentity(_ value: String) -> String {
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
}

enum MobileRPCConnectAdmission: Sendable, Equatable {
    case granted(MobileRPCConnectAttemptLease)
    case busy
    case cleanupBlocked
}

struct MobileRPCConnectRouteState {
    var activeLeaseID: UUID?
    var physicalCleanupTasks: [UUID: Task<Void, Never>] = [:]
}
