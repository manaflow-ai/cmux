import CMUXMobileCore

struct FixedTransportFactory: CmxByteTransportFactory {
    let transport: any CmxByteTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
