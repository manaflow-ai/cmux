internal import CMUXMobileCore
import Foundation

/// In-memory identity for one physical peer route.
///
/// Diagnostic route descriptions intentionally redact peer identities and
/// path hints change as network reachability changes. Admission instead keys
/// Iroh routes by the authenticated endpoint identity plus expected Mac, so
/// cleanup debt neither leaks across Macs nor disappears on a hint refresh.
struct MobileRPCConnectAttemptKey: Hashable, Sendable {
    enum EndpointIdentity: Hashable, Sendable {
        case iroh(endpointID: String)
        case hostPort(kind: String, host: String, port: Int)
        case transport(kind: String)
    }

    let expectedPeerDeviceID: String
    let endpointIdentity: EndpointIdentity

    init(route: CmxAttachRoute, expectedPeerDeviceID: String) {
        self.expectedPeerDeviceID = cmxCanonicalDeviceID(
            expectedPeerDeviceID
        )
        switch route.endpoint {
        case let .peer(identity, _):
            endpointIdentity = .iroh(endpointID: identity.endpointID)
        case let .hostPort(host, port):
            endpointIdentity = .hostPort(
                kind: route.kind.rawValue,
                host: host.lowercased(),
                port: port
            )
        case .url:
            // URL query parameters may contain rotating credentials and
            // equivalent endpoint spellings. The authenticated Mac plus
            // transport kind is the stable peer boundary for cleanup debt.
            endpointIdentity = .transport(kind: route.kind.rawValue)
        }
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
