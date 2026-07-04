import CMUXMobileCore
import CmuxMobileRPC

struct AuthorizationFailingTransportFactory: CmxByteTransportFactory {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        _ = route
        return AuthorizationFailingTransport()
    }
}
