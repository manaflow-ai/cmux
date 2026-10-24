import CmuxNextCompat
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Every request the app waits on is a `daemon.request` interval named by its `cmd` and the
/// client-minted id the request line carries (the id the daemon's span records), ended when the
/// reply reaches the requester. A one-reply socket server stands in for the daemon.
@Suite(.timeLimit(.minutes(1)))
struct DaemonRequestSignpostTests {
    final class Recorder: DaemonRequestSignposting {
        let events = Mutex<[String]>([])
        func begin(method: String, id: UInt64) -> DaemonRequestSignpost {
            events.withLock { $0.append("begin method=\(method) id=\(id)") }
            return DaemonRequestSignpost(id: id, interval: nil)
        }
        func end(_ signpost: DaemonRequestSignpost) { events.withLock { $0.append("end id=\(signpost.id)") } }
    }

    @Test func aRequestIsOneIntervalWithItsMethodAndTheIDItsLineCarries() async throws {
        let path = "/tmp/cx-sp-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let server = try OneReplyServer(path: path)
        let recorder = Recorder()
        let transport = try LineTransport(path: path, requestSignposts: recorder)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        _ = try await transport.request(cmd: "ping", timeout: .seconds(10)) { id in Data(#"{"id":\#(id),"cmd":"ping"}"#.utf8) }
        let sentID = try #require(server.receivedID())
        #expect(recorder.events.withLock { $0 } == ["begin method=ping id=\(sentID)", "end id=\(sentID)"])
    }
}

/// Accepts one connection, reads one request line, and answers `{"id": <its id>, "ok": true}`.
private final class OneReplyServer: Sendable {
    private let id = Mutex<UInt64?>(nil)

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0.prefix(raw.count - 1)) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        let id = id
        Thread.detachNewThread {
            defer { close(fd) }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var line = Data()
            var byte: UInt8 = 0
            while read(client, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let number = (object["id"] as? NSNumber)?.uint64Value else { return }
            id.withLock { $0 = number }
            let reply = Data(#"{"id":\#(number),"ok":true}"#.utf8) + Data([0x0A])
            _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
            // Keep the connection open until the client closes it.
            while read(client, &byte, 1) == 1 {}
        }
    }

    func receivedID() -> UInt64? { id.withLock { $0 } }
}
