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
        case url(kind: String, value: String)
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
        case let .url(value):
            endpointIdentity = .url(
                kind: route.kind.rawValue,
                value: value
            )
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
