import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemon Network WebSocket transport lifecycle")
struct RemoteDaemonWebSocketTransportTests {
    @Test("WebSocket transport rejects non-WebSocket URLs before opening a connection")
    func rejectsInvalidScheme() {
        let request = URLRequest(url: URL(string: "https://127.0.0.1/daemon")!)
        #expect(throws: URLError.self) {
            _ = try RemoteDaemonWebSocketConnection(
                request: request,
                callbackQueue: DispatchQueue(label: "remote-daemon-websocket-test")
            )
        }
    }

    @Test("cancelling a WebSocket transport marks it closed and unblocks open waiters")
    func cancellationIsTerminal() throws {
        let request = URLRequest(url: URL(string: "ws://127.0.0.1:1/daemon")!)
        let connection = try RemoteDaemonWebSocketConnection(
            request: request,
            callbackQueue: DispatchQueue(label: "remote-daemon-websocket-test")
        )
        connection.cancel()
        #expect(connection.isClosed)
        #expect(!connection.waitForOpen(timeout: 0))
    }
}
