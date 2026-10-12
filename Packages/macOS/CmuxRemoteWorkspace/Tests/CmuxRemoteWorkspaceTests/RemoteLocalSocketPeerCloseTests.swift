import CmuxFoundation
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// Unix socket server that accepts one client, reads a single byte so the
/// client is known to be mid-write, then closes the connection.
private final class ClosingAfterFirstByteSocketServer: @unchecked Sendable {
    let path: String
    private let listenFD: Int32
    private let finished = DispatchSemaphore(value: 0)

    init() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-peer-close-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("s.sock").path

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { rawBuffer in
            let destination = rawBuffer.baseAddress!.advanced(by: sunPathOffset)
            pathBytes.withUnsafeBytes { pathBuffer in
                destination.copyMemory(from: pathBuffer.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let addressLength = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, addressLength)
            }
        }
        guard bindResult == 0, Darwin.listen(listenFD, 1) == 0 else {
            Darwin.close(listenFD)
            throw POSIXError(.EIO)
        }

        let listenFD = listenFD
        let finished = finished
        DispatchQueue.global().async {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.read(clientFD, &byte, 1)
                Darwin.close(clientFD)
            }
            finished.signal()
        }
    }

    func waitUntilFinished() -> Bool {
        finished.wait(timeout: .now() + 10) == .success
    }

    func close() {
        Darwin.close(listenFD)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }
}

/// A local cmux socket that closes mid-request must surface as a thrown
/// error. Without SO_NOSIGPIPE the write raises SIGPIPE and the default
/// action terminates the whole process (the cmux app, or this test runner).
@Suite("Local cmux socket closed mid-request")
struct RemoteLocalSocketPeerCloseTests {
    /// Larger than any Unix socket send buffer, so the write is still in
    /// flight when the peer closes.
    private let oversizedRequest = Data(repeating: 0x61, count: 8 * 1024 * 1024) + Data([0x0A])

    @Test("relay sockets suppress SIGPIPE")
    func relaySocketDescriptorSuppressesSIGPIPE() throws {
        let fd = try RemoteCLIRelayServer.Session.makeLocalSocketDescriptor()
        defer { Darwin.close(fd) }
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &length) == 0)
        #expect(value != 0)
    }

    @Test("the relay throws instead of raising SIGPIPE when the local socket closes")
    func relayRoundTripThrowsOnPeerClose() throws {
        let server = try ClosingAfterFirstByteSocketServer()
        defer { server.close() }
        let fd = try RemoteCLIRelayServer.Session.makeLocalSocketDescriptor()
        defer { Darwin.close(fd) }

        #expect(throws: (any Error).self) {
            _ = try RemoteCLIRelayServer.Session.roundTripUnixSocket(
                socketDescriptor: fd,
                socketPath: server.path,
                peerCheck: UnixSocketPeerCheck(),
                request: oversizedRequest,
                maximumResponseBytes: 1024,
                shouldContinue: { true }
            )
        }
        #expect(server.waitUntilFinished())
    }

    @Test("the Cloud CLI bridge throws instead of raising SIGPIPE when the local socket closes")
    func bridgeRoundTripThrowsOnPeerClose() throws {
        let server = try ClosingAfterFirstByteSocketServer()
        defer { server.close() }

        #expect(throws: (any Error).self) {
            _ = try RemoteDaemonProxyTunnel.roundTripUnixSocket(
                socketPath: server.path,
                request: oversizedRequest,
                socketPassword: { nil }
            )
        }
        #expect(server.waitUntilFinished())
    }
}
