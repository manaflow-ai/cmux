import CmuxNextCompat
@testable import CmuxNextTasks
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// An owner that accepts every connection and answers with a snapshot the mirror refuses (two
/// tasks with one id). The source must close, say why, and space its reconnects by a growing
/// backoff: the backoff resets on a valid snapshot, not on connect, so it never retries this
/// owner every 200 ms forever (p10-stability-096).
@MainActor
struct SocketTasksSourceBadSnapshotTests {
    private struct SnapshotLine: Encodable {
        var snapshot: TasksSnapshot
    }

    @MainActor
    private final class Disconnects {
        var reasons: [String] = []
    }

    @Test func aRefusedSnapshotBacksOffMoreOnEachReconnect() async throws {
        var snapshot = MockTasksSource.seed()
        snapshot.tasks.append(try #require(snapshot.tasks.first))
        var line = try JSONEncoder().encode(SnapshotLine(snapshot: snapshot))
        line.append(UInt8(ascii: "\n"))
        let owner = try BadSnapshotOwner(line: line)
        defer { owner.close() }

        let clock = ManualClock()
        // A scheduler with no display link: each read's lines run on the next main run loop pass.
        let source = SocketTasksSource(path: owner.path,
                                       mainWork: MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil },
                                       retryTimer: DemandTimer(owner: "test.tasks.reconnect", clock: clock, ledger: WakeupLedger()),
                                       backoff: Backoff(initial: .milliseconds(200), maximum: .seconds(10), jitter: 0))
        let disconnects = Disconnects()
        source.start { event in
            if case let .connection(.disconnected(reason)) = event { disconnects.reasons.append(reason) }
        }
        defer { source.stop() }

        // Each sleep starts only after a connection got the refused snapshot and closed.
        var delays: [Double] = []
        for _ in 0..<3 {
            try await clock.waitForSleeper()
            let request = try #require(clock.sleepRequests.last)
            let delay = clock.now.duration(to: request.deadline)
            delays.append(delay.inSeconds)
            clock.advance(by: delay)
        }

        #expect(delays.count == 3)
        for (delay, expected) in zip(delays, [0.2, 0.4, 0.8]) {
            #expect(abs(delay - expected) < 0.000_001, "reconnect delays \(delays)")
        }
        #expect(disconnects.reasons.count >= 3)
        #expect(disconnects.reasons.allSatisfy { $0 == TasksStrings.ownerSentBadSnapshot })
    }
}

/// A unix socket in its own directory (so no other test's files wake the source's directory watch)
/// that writes `line` to every connection it accepts and keeps the connection open, so the only
/// reason the source closes is the line. Nonisolated: its accept handler runs on its own queue.
private nonisolated final class BadSnapshotOwner: Sendable {
    let path: String
    private let directory: String
    private let descriptor: Int32
    private let reader: any DispatchSourceRead
    private let peers: Peers

    init(line: Data) throws {
        let directory = NSTemporaryDirectory() + "tasks-bad-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/tasks.sock"
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
        guard descriptor >= 0, bound == 0, listen(descriptor, 8) == 0 else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
        let listener = descriptor
        let peers = Peers()
        let reader = DispatchSource.makeReadSource(fileDescriptor: listener,
                                                   queue: DispatchQueue(label: "cmux.test.tasks-bad-snapshot"))
        reader.setEventHandler { @Sendable in
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            line.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { _ = send(peer, base, bytes.count, 0) }
            }
            peers.add(peer)
        }
        self.path = path
        self.directory = directory
        self.descriptor = descriptor
        self.peers = peers
        self.reader = reader
        reader.resume()
    }

    func close() {
        reader.cancel()
        Darwin.close(descriptor)
        peers.closeAll()
        unlink(path)
        rmdir(directory)
    }
}

/// The accepted descriptors, written on the owner's queue and closed by the test.
private nonisolated final class Peers: Sendable {
    private let descriptors = Mutex<[Int32]>([])

    func add(_ descriptor: Int32) {
        descriptors.withLock { $0.append(descriptor) }
    }

    func closeAll() {
        for descriptor in descriptors.withLock({ $0 }) { Darwin.close(descriptor) }
    }
}
