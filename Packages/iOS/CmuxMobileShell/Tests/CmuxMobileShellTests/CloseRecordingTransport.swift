import CMUXMobileCore
import Foundation

actor CloseRecordingTransport: CmxByteTransport {
    private let factory: CloseRecordingTransportFactory

    init(factory: CloseRecordingTransportFactory) {
        self.factory = factory
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {
        throw NSError(domain: "IrohStoredReconnectRegressionTests", code: 2)
    }

    func close() async {
        factory.recordClose()
    }
}
