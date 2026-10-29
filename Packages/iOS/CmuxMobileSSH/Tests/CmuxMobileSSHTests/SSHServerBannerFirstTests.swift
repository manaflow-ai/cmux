@testable import CmuxMobileSSH
import Darwin
import Foundation
import Testing

/// SSH servers (OpenSSH, AsyncSSH) send their version line the moment they
/// accept. The client must be listening for it from the instant the TCP
/// connection is up, or the line is dropped and the handshake stalls until
/// the connect timeout. This happened on every app launch in the simulator,
/// when a busy cooperative pool delayed the caller's resumption after the
/// TCP connect.
@Suite struct SSHServerBannerFirstTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test func versionLineSentBeforeCallerResumesIsNotLost() async throws {
        let server = try BannerFirstServer()
        let executor = BlockableTaskExecutor()
        let task = Task(executorPreference: executor) {
            try? await SSHConnection.connect(
                to: SSHEndpoint(host: "127.0.0.1", port: server.port, username: "probe"),
                credentials: [],
                hostKeyVerifier: AcceptAnyVerifier(),
                connectTimeout: .seconds(3)
            )
        }
        // Queued behind the connect's first job: the connect starts, suspends
        // on the TCP connect, and its resumption waits here while the server's
        // version line arrives.
        executor.block(for: 0.5)
        _ = await task.value
        #expect(server.waitForClientKeyExchange(timeout: 5), "the client never answered the server's version line")
    }
}

private struct AcceptAnyVerifier: SSHHostKeyVerifier {
    func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool { true }
}

/// Runs task jobs on one serial queue that the test can stall.
@available(macOS 15.0, iOS 18.0, *)
private final class BlockableTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.ssh.test.blockable-executor")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    func block(for seconds: TimeInterval) {
        queue.async { Thread.sleep(forTimeInterval: seconds) }
    }
}

/// A TCP server that writes an SSH version line immediately on accept, then
/// reports whether the client sent anything after its own version line (its
/// KEXINIT), which it can only do after reading the server's line.
private final class BannerFirstServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let sawKeyExchange = DispatchSemaphore(value: 0)

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        // SAFETY: inet_addr reads the NUL-terminated copy of the literal made for this call.
        address.sin_addr.s_addr = unsafe inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        // SAFETY: bind reads `length` (sizeof(sockaddr_in)) bytes from `address`, a sockaddr_in
        // local; the sockaddr view is the socket API's cast, used only for the call.
        let bound = unsafe withUnsafePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(listener, $0, length) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        // SAFETY: getsockname writes at most `length` bytes into `address` and updates `length`.
        _ = unsafe withUnsafeMutablePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe getsockname(listener, $0, &length) }
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        let signal = sawKeyExchange
        Thread.detachNewThread {
            // SAFETY: nil address and length ask accept for no peer address; nothing is written.
            let client = unsafe accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            let banner = Array("SSH-2.0-BannerFirst_1.0\r\n".utf8)
            // SAFETY: write reads banner.count bytes, the count passed, from `banner`.
            _ = unsafe write(client, banner, banner.count)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            // SAFETY: setsockopt reads sizeof(timeval) bytes, the length passed, from `timeout`.
            unsafe setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var received: [UInt8] = []
            let capacity = 4096
            var buffer = [UInt8](repeating: 0, count: capacity)
            while true {
                // SAFETY: read writes at most `capacity` bytes, the size passed, into `buffer`,
                // which holds that many.
                let count = unsafe read(client, &buffer, capacity)
                guard count > 0 else { return }
                received += buffer[0..<count]
                if let newline = received.firstIndex(of: 0x0A), received.count > newline + 1 {
                    signal.signal()
                    return
                }
            }
        }
    }

    deinit { close(listener) }

    func waitForClientKeyExchange(timeout: TimeInterval) -> Bool {
        sawKeyExchange.wait(timeout: .now() + timeout) == .success
    }
}
