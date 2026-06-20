import CMUXMobileCore
import Foundation

actor CancelCallerAfterConnectTransport: CmxByteTransport {
    private var isClosed = false
    private(set) var sendCount = 0

    func connect() async throws {}

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {
        sendCount += 1
    }

    func close() async {
        isClosed = true
    }

    func closed() -> Bool {
        isClosed
    }
}
