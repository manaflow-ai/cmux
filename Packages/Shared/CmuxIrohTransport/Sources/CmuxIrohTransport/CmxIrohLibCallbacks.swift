import IrohLib

final class CmxIrohLibAddressChangeCallback: AddrChangeCallback, Sendable {
    private let handler: @Sendable (EndpointAddr) async -> Void

    init(handler: @escaping @Sendable (EndpointAddr) async -> Void) {
        self.handler = handler
    }

    func onChange(addr: EndpointAddr) async throws {
        await handler(addr)
    }
}
