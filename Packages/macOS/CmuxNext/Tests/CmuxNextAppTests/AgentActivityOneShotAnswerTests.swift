@testable import CmuxNextAgentActivity
import CmuxNextCompat
import struct CmuxSafeConcurrency.OnceContinuationFault
import struct CmuxSafeConcurrency.OnceContinuationFaultReporter
import Darwin
import Foundation
import Testing

/// `AgentActivityLineConnection.oneShot` resumes its one continuation exactly once: the first reply
/// line answers, and the lines after it in the same read, the server's close and the deadline find
/// the call answered (its private resume-once box is gone, so a second resume
/// would be a `resumedTwice` fault here).
struct AgentActivityOneShotAnswerTests {
    @Test func theFirstLineAnswersAndNothingResumesAgain() async throws {
        let server = try AnsweringServer(reply: Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        defer { server.close() }
        let faults = FaultLog()
        let line = try await AgentActivityLineConnection.oneShot(path: server.path, send: Data("{}\n".utf8),
                                                                 deadline: .seconds(20), acceptsServer: nil,
                                                                 faults: faults.reporter)
        #expect(String(decoding: line, as: UTF8.self) == "{\"a\":1}")
        // The server closes after its reply; the connection already ended, so the close calls nothing.
        await server.closed()
        #expect(faults.recorded.isEmpty)
    }

    @Test func aServerThatClosesWithoutAReplyAnswersClosed() async throws {
        let server = try AnsweringServer(reply: Data())
        defer { server.close() }
        let faults = FaultLog()
        await #expect(throws: AgentActivitySourceError.closed) {
            try await AgentActivityLineConnection.oneShot(path: server.path, send: Data("{}\n".utf8),
                                                          deadline: .seconds(20), acceptsServer: nil, faults: faults.reporter)
        }
        #expect(faults.recorded.isEmpty)
    }
}

/// The faults the call under test reports, in order. Nonisolated: the reporter runs on the connection's queue.
private nonisolated final class FaultLog: Sendable {
    private let faults = Mutex<[OnceContinuationFault]>([])

    var reporter: OnceContinuationFaultReporter {
        OnceContinuationFaultReporter { fault in self.record(fault) }
    }

    func record(_ fault: OnceContinuationFault) {
        faults.withLock { $0.append(fault) }
    }

    var recorded: [OnceContinuationFault] {
        faults.withLock { $0 }
    }
}

/// A unix socket that accepts one connection, reads its request, writes `reply` in one send, and closes
/// it. Nonisolated: its accept handler runs on its own queue.
private nonisolated final class AnsweringServer: Sendable {
    let path: String
    private let descriptor: Int32
    private let reader: any DispatchSourceRead
    private let done: AsyncStream<Void>

    init(reply: Data) throws {
        let path = NSTemporaryDirectory() + "oneshot-answer-\(UUID().uuidString.prefix(8)).sock"
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard descriptor >= 0, bound == 0, listen(descriptor, 4) == 0 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
        let (done, finish) = AsyncStream<Void>.makeStream()
        let listener = descriptor
        let reader = DispatchSource.makeReadSource(fileDescriptor: listener,
                                                   queue: DispatchQueue(label: "cmux.test.oneshot-answer"))
        reader.setEventHandler { @Sendable [reader] in
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            reader.cancel()
            // Read the request first: a close before the client's send would fail that send and end the
            // call as `closed` before it reads the reply.
            var request = [UInt8](repeating: 0, count: 256)
            _ = recv(peer, &request, request.count, 0)
            reply.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { _ = send(peer, base, bytes.count, 0) }
            }
            Darwin.close(peer)
            finish.yield()
            finish.finish()
        }
        self.path = path
        self.descriptor = descriptor
        self.done = done
        self.reader = reader
        reader.resume()
    }

    /// Returns once the server wrote its reply and closed the connection.
    func closed() async {
        for await _ in done { return }
    }

    func close() {
        reader.cancel()
        Darwin.close(descriptor)
        unlink(path)
    }
}
