import CmuxSafeConcurrency
import Darwin
import Foundation
import Testing

@testable import CmuxIrxTransport

/// The real Network.framework connector and the exactly-once outcome that
/// settles its connect from state change, deadline or cancellation. The
/// outcome cases record the OnceContinuation's faults: a double resume or a
/// dropped continuation is one, so no fault proves exactly one resume. Run under TSan
/// (`swift test --sanitize=thread --filter IrxTunnelNetworkConnectorTests`).
@Suite("tunnel network connector", .serialized)
struct IrxTunnelNetworkConnectorTests {
    private static let loopback = IrxTunnelIPAddress.v4([127, 0, 0, 1])

    @Test func connectsToALoopbackListenerAndRelaysBytes() async throws {
        let server = try TunnelTestTCPServer(mode: .echo)
        defer { server.stop() }
        let channel = try await IrxTunnelNetworkConnector().connect(
            to: [Self.loopback], port: server.port, timeout: .seconds(10)
        )
        defer { channel.cancel() }

        try await channel.send(Data("ping".utf8))
        await channel.finishSending()
        var received = Data()
        while let chunk = try await channel.receive(maximumByteCount: 1024) {
            received.append(chunk)
        }
        #expect(String(decoding: received, as: UTF8.self) == "ping<eof>")
    }

    @Test func closedLoopbackPortIsRefused() async throws {
        let port = try Self.closedLoopbackPort()
        let error = await Self.openError { () async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel in
            try await IrxTunnelNetworkConnector().connect(to: [Self.loopback], port: port, timeout: .seconds(10))
        }
        #expect(error == IrxTunnelOpenError(status: .refused))
    }

    /// The deadline settles before the connection can: the injected sleep
    /// returns at once, and TEST-NET-1 (RFC 5737) never answers.
    @Test func elapsedDeadlineIsTimedOut() async {
        let connector = IrxTunnelNetworkConnector(sleep: { _ in })
        let error = await Self.openError { () async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel in
            try await connector.connect(to: [.v4([192, 0, 2, 1])], port: 9, timeout: .seconds(10))
        }
        #expect(error == IrxTunnelOpenError(status: .timedOut))
    }

    /// A task cancelled before it connects settles through the cancellation
    /// handler, which runs before the continuation is installed.
    @Test func cancelledTaskFailsWithoutConnecting() async throws {
        let server = try TunnelTestTCPServer(mode: .echo)
        defer { server.stop() }
        let error = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Self.openError { () async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel in
                try await IrxTunnelNetworkConnector().connect(
                    to: [Self.loopback], port: server.port, timeout: .seconds(10)
                )
            }
        }.value
        #expect(error == IrxTunnelOpenError(status: .failed))
    }

    @Test func outcomeSettledBeforeInstallResumesWithTheFirstResult() async {
        let faults = ConnectOutcomeFaults()
        let outcome = IrxTunnelConnectOutcome()
        outcome.finish(.failure(IrxTunnelOpenError(status: .refused)))
        let result = try? await withOnceContinuation(faults: faults.reporter) { continuation in
            for _ in 0..<64 {
                Task.detached { outcome.finish(.failure(IrxTunnelOpenError(status: .timedOut))) }
            }
            outcome.install(continuation)
        }
        #expect(result.flatMap(Self.status) == .refused)
        #expect(faults.recorded.isEmpty)
    }

    @Test func racingFinishesResumeTheInstalledContinuationOnce() async {
        let statuses: [IrxTunnelOpenReply.Status] = [.refused, .timedOut, .failed, .hostUnreachable]
        let faults = ConnectOutcomeFaults()
        for _ in 0..<200 {
            let outcome = IrxTunnelConnectOutcome()
            let result = try? await withOnceContinuation(faults: faults.reporter) { continuation in
                for status in statuses {
                    Task.detached { outcome.finish(.failure(IrxTunnelOpenError(status: status))) }
                }
                Task.detached { outcome.finish(.success(())) }
                outcome.install(continuation)
            }
            #expect(result != nil)
            #expect(result.flatMap(Self.status).map { statuses.contains($0) } ?? true)
        }
        #expect(faults.recorded.isEmpty)
    }

    private static func status(_ result: Result<Void, IrxTunnelOpenError>) -> IrxTunnelOpenReply.Status? {
        switch result {
        case .success: nil
        case .failure(let error): error.status
        }
    }

    private static func openError(
        _ open: () async throws(IrxTunnelOpenError) -> any IrxTunnelByteChannel
    ) async -> IrxTunnelOpenError? {
        do {
            let channel = try await open()
            channel.cancel()
            return nil
        } catch {
            return error
        }
    }

    /// A loopback port that was bound and closed, so nothing listens on it.
    private static func closedLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// The faults the connect outcome's continuations report, from any thread.
private final class ConnectOutcomeFaults: Sendable {
    private let faults = Mutex<[OnceContinuationFault]>([])

    var reporter: OnceContinuationFaultReporter {
        OnceContinuationFaultReporter { fault in self.faults.withLock { $0.append(fault) } }
    }

    var recorded: [OnceContinuationFault] {
        faults.withLock { $0 }
    }
}
