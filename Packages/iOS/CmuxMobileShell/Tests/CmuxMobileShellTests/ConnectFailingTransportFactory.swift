import CMUXMobileCore

struct ConnectFailingTransportFactory: CmxByteTransportFactory {
    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        ConnectFailingTransport()
    }
}
