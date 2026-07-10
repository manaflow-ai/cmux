import IrohLib

final class CmxIrohLibNetworkChangeCallback: NetworkChangeCallback, Sendable {
    private let handler: @Sendable () async -> Void

    init(handler: @escaping @Sendable () async -> Void) {
        self.handler = handler
    }

    func onChange() async throws {
        await handler()
    }
}

final class CmxIrohLibAddressChangeCallback: AddrChangeCallback, Sendable {
    private let handler: @Sendable () async -> Void

    init(handler: @escaping @Sendable () async -> Void) {
        self.handler = handler
    }

    func onChange(addr _: EndpointAddr) async throws {
        await handler()
    }
}
