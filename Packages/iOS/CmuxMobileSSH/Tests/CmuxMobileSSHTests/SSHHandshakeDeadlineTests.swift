@testable import CmuxMobileSSH
import Darwin
import Foundation
import NIOCore
import NIOEmbedded
import Testing

/// The handshake budget bounds network phases but pauses while host key
/// verification waits on the user (a trust prompt must never time out).
struct SSHHandshakeDeadlineTests {
    @Test func pausedTimeIsNotSpent() {
        let loop = EmbeddedEventLoop()
        let deadline = SSHHandshakeDeadline(timeout: .seconds(1), eventLoop: loop)
        let work = loop.makePromise(of: Void.self)
        deadline.complete(with: work.futureResult)
        var outcome: Result<Void, any Error>?
        deadline.futureResult.whenComplete { outcome = $0 }

        loop.advanceTime(by: .milliseconds(600))
        deadline.pause()
        loop.advanceTime(by: .seconds(60))
        #expect(outcome == nil, "a pending verification must not spend the budget")
        deadline.resume()
        loop.advanceTime(by: .milliseconds(300))
        #expect(outcome == nil, "only 0.9 s of the 1 s budget has been spent")
        loop.advanceTime(by: .milliseconds(200))
        guard case .failure(let error)? = outcome, case ChannelError.connectTimeout = error else {
            Issue.record("expected connectTimeout, got \(String(describing: outcome))")
            return
        }
        work.succeed(())
    }

    @Test func nestedPausesResumeOnlyAfterTheLast() {
        let loop = EmbeddedEventLoop()
        let deadline = SSHHandshakeDeadline(timeout: .seconds(1), eventLoop: loop)
        let work = loop.makePromise(of: Void.self)
        deadline.complete(with: work.futureResult)
        var finished = false
        deadline.futureResult.whenComplete { _ in finished = true }
        deadline.pause()
        deadline.pause()
        deadline.resume()
        loop.advanceTime(by: .seconds(5))
        #expect(!finished)
        deadline.resume()
        loop.advanceTime(by: .seconds(1))
        #expect(finished)
        work.succeed(())
    }

    @Test func workCompletingFirstWins() throws {
        let loop = EmbeddedEventLoop()
        let deadline = SSHHandshakeDeadline(timeout: .seconds(1), eventLoop: loop)
        let work = loop.makePromise(of: Void.self)
        deadline.complete(with: work.futureResult)
        var outcome: Result<Void, any Error>?
        deadline.futureResult.whenComplete { outcome = $0 }
        work.fail(SSHConnectionError.authenticationFailed)
        loop.advanceTime(by: .seconds(2))
        guard case .failure(SSHConnectionError.authenticationFailed)? = outcome else {
            Issue.record("expected the work's own error, got \(String(describing: outcome))")
            return
        }
    }

    /// A server that accepts TCP but never speaks SSH still times out.
    @Test(.timeLimit(.minutes(1))) func silentServerTimesOut() async throws {
        let listener = try SilentListener()
        defer { listener.close() }
        let started = ContinuousClock.now
        do {
            _ = try await SSHConnection.connect(
                to: SSHEndpoint(host: "127.0.0.1", port: listener.port, username: "nobody"),
                credentials: [],
                hostKeyVerifier: AcceptAllVerifier(),
                connectTimeout: .milliseconds(500)
            )
            Issue.record("connect to a silent server must not succeed")
        } catch ChannelError.connectTimeout {
            #expect(ContinuousClock.now - started < .seconds(5))
        }
    }
}

private struct AcceptAllVerifier: SSHHostKeyVerifier {
    func verify(_ key: SSHHostKey, for endpoint: SSHEndpoint) async -> Bool { true }
}

/// A loopback TCP listener that completes handshakes in the kernel backlog
/// and never reads or writes.
private final class SilentListener {
    let fd: Int32
    let port: Int

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() { Darwin.close(fd) }
}
