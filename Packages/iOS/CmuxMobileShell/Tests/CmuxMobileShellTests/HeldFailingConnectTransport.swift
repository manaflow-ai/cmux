import CMUXMobileCore
import Foundation

actor HeldFailingConnectTransport: CmxByteTransport {
    private let factory: RouteRecordingTransportFactory

    init(factory: RouteRecordingTransportFactory) {
        self.factory = factory
    }

    func connect() async throws {
        await factory.waitUntilHeldConnectReleased()
        throw RouteRecordingTransportError.routeFailed
    }

    func receive() async throws -> Data? { nil }
    func send(_ data: Data) async throws {}
    func close() async {}
}
