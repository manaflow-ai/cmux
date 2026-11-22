@testable import CmuxNextMacScreen
import Darwin
import Foundation
import Testing

/// A failed ownership handshake must release the worker's app-channel claim. Otherwise an old
/// worker or a refused subscription leaves an orphan channel that disables standalone hosting.
struct CmuxRemoteChannelOwnershipTests {
    @Test(arguments: [false, true])
    func rejectedHandshakeClosesTheAppChannel(subscription: Bool) async throws {
        var pair = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let client = pair[0], server = pair[1]
        // task-owner: this test's fake worker owns its socket and ends after one request and EOF.
        let worker = Task.detached(priority: .userInitiated) {
            defer { Darwin.close(server) }
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            _ = setsockopt(server, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard let request = RemoteSocket.readLine(server),
                  let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any],
                  let id = object["id"] as? Int else { return false }
            let response: [String: Any] = ["id": id, "ok": false, "error": ["message": "unsupported ownership mode"]]
            guard let encoded = try? JSONSerialization.data(withJSONObject: response),
                  RemoteSocket.writeAll(server, encoded + Data([0x0A])) else { return false }
            var byte: UInt8 = 0
            // A clean EOF proves the claim was released; a timeout (-1) does not.
            return Darwin.read(server, &byte, 1) == 0 && object["method"] as? String == "host.mode"
        }
        let devices = CmuxRemoteDevices(open: { client })
        do {
            if subscription {
                let connection = try await devices.subscribe()
                connection.close()
            } else {
                _ = try await devices.identity()
            }
            Issue.record("the refused ownership handshake succeeded")
        } catch {
            // The next assertion proves cleanup as well as refusal.
        }
        #expect(await worker.value)
    }
}
