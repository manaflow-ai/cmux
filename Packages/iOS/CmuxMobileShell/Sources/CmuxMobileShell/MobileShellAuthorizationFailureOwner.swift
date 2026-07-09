import CMUXMobileCore
import CmuxMobileRPC

/// The connection whose request produced an authorization failure.
enum MobileShellAuthorizationFailureOwner {
    case foreground(route: CmxAttachRoute?)
    case connectionAttempt(route: CmxAttachRoute?, preservingActiveConnection: Bool)
    case secondary(macDeviceID: String, client: MobileCoreRPCClient, route: CmxAttachRoute)

    var route: CmxAttachRoute? {
        switch self {
        case let .foreground(route), let .connectionAttempt(route, _):
            route
        case let .secondary(_, _, route):
            route
        }
    }

    var preservesActiveConnection: Bool {
        switch self {
        case .foreground:
            false
        case let .connectionAttempt(_, preservingActiveConnection):
            preservingActiveConnection
        case .secondary:
            true
        }
    }
}
