import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct CDPConnectionTests {
    @Test func requestFailsAtItsDeadlineWhenChromiumNeverReplies() async {
        let connection = CDPConnection(
            transport: NoResponseCDPWebSocketTransport(),
            requestTimeout: .milliseconds(20)
        )

        await #expect(throws: BrowserEngineSessionError.self) {
            _ = try await connection.send(method: "Runtime.evaluate")
        }
        await connection.close()
    }

    @Test func cancellingCallerCancelsItsPendingRequest() async {
        let connection = CDPConnection(
            transport: NoResponseCDPWebSocketTransport(),
            requestTimeout: .seconds(5)
        )
        let request = Task {
            try await connection.send(method: "Page.captureScreenshot")
        }
        await Task.yield()

        request.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await request.value
        }
        await connection.close()
    }
}

private final class NoResponseCDPWebSocketTransport: CDPWebSocketTransport, @unchecked Sendable {
    func resume() {}

    func send(_: Data) async throws {}

    func receive() async throws -> Data {
        try await ContinuousClock().sleep(for: .seconds(60))
        return Data()
    }

    func cancel() {}
}
