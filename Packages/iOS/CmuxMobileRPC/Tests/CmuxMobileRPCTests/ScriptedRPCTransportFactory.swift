import CMUXMobileCore

struct ScriptedRPCTransportFactory: CmxByteTransportFactory {
    let transport: ScriptedRPCTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
