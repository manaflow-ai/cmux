import CMUXMobileCore
@testable import CmuxMobileRPC

struct ResponseTimeoutSurvivalTransportFactory: CmxByteTransportFactory {
    let transport: ResponseTimeoutSurvivalTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
