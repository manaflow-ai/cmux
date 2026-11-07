import CmuxFoundation
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// Adds an inert parameter large enough that the relay's write to the local
/// socket cannot finish until the local server reads.
private struct PaddingRelayRewriter: RemoteRelayCommandRewriting {
    let paddingBytes: Int

    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data {
        guard let line = String(data: commandLine, encoding: .utf8),
              let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return commandLine
        }
        var params = request["params"] as? [String: Any] ?? [:]
        params["_cmux_remote_workspace_id"] = UUID().uuidString
        params["_cmux_remote_relay_request_authentication_code"] = "test"
        params["padding"] = String(repeating: "x", count: paddingBytes)
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)).map { $0 + Data([0x0A]) } ?? commandLine
    }
}

/// Local socket stand-in that accepts the relay's connection and never reads
/// it, so a forwarded line larger than the socket buffer leaves the relay
/// blocked in its write.
private final class StalledUnixSocketListener {
    let path: String
    private let listenFD: Int32
    private var acceptedFD: Int32 = -1

    init() throws {
        path = NSTemporaryDirectory() + "cmux-relay-stall-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "StalledUnixSocketListener", code: Int(errno))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        precondition(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: offset).copyMemory(from: src.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let len = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let failure = errno  // capture before close() can overwrite errno
            Darwin.close(fd)
            throw NSError(domain: "StalledUnixSocketListener", code: Int(failure))
        }
        listenFD = fd
    }

    /// Accepts the relay's connection and waits for its first bytes, which
    /// means the relay is inside its write.
    func waitForIncomingBytes(timeoutMilliseconds: Int32 = 5_000) -> Bool {
        var pendingConnection = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        guard poll(&pendingConnection, 1, timeoutMilliseconds) == 1 else { return false }
        acceptedFD = accept(listenFD, nil, nil)
        guard acceptedFD >= 0 else { return false }
        var incomingBytes = pollfd(fd: acceptedFD, events: Int16(POLLIN), revents: 0)
        return poll(&incomingBytes, 1, timeoutMilliseconds) == 1
    }

    /// Drains what the relay wrote and reports whether it then hung up.
    func waitForHangUp(timeout: TimeInterval = 5) -> Bool {
        guard acceptedFD >= 0 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var scratch = [UInt8](repeating: 0, count: 65_536)
        while Date() < deadline {
            var readable = pollfd(fd: acceptedFD, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, 100) == 1 else { continue }
            let count = Darwin.read(acceptedFD, &scratch, scratch.count)
            if count == 0 { return true }
            if count < 0 { return false }
        }
        return false
    }

    func close() {
        if acceptedFD >= 0 {
            Darwin.close(acceptedFD)
        }
        Darwin.close(listenFD)
        unlink(path)
    }
}

extension RemoteCLIRelayServerTests {
    @Test("stopping the relay during a blocked local socket write fails the write without SIGPIPE")
    func stopInterruptsBlockedLocalSocketWrite() throws {
        let localSocket = try StalledUnixSocketListener()
        defer { localSocket.close() }
        let server = try RemoteCLIRelayServer(
            localSocketPath: localSocket.path,
            relayID: "relay-1",
            relayTokenHex: tokenHex,
            commandRewriter: PaddingRelayRewriter(paddingBytes: 1 << 20)
        )
        defer { server.stop() }
        let port = try server.start()
        let client = RelayTestClient(port: port)
        defer { client.cancel() }

        try authenticate(client)
        client.send(Data((#"{"id":"relay-test","method":"system.ping","params":{}}"# + "\n").utf8))
        #expect(
            localSocket.waitForIncomingBytes(),
            "The relay must be writing the forwarded line when it stops"
        )

        // Session teardown shuts the socket down under the blocked write. The
        // test process surviving this call is the SIGPIPE assertion.
        server.stop()

        #expect(
            localSocket.waitForHangUp(),
            "The relay must close its local socket after the interrupted write"
        )
    }
}
