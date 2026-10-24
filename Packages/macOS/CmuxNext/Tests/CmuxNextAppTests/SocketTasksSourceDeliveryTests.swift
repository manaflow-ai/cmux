import CmuxNextTasks
import Darwin
import Foundation
import Testing

/// The Tasks owner's lines reach `SocketTasksSource`'s sink on the main thread, in the order the
/// owner wrote them: the connection decodes on its own queue and hands each read to the main queue
/// through `MainDelivery` (it was a hand-written `DispatchQueue.main.async` plus
/// `MainActor.assumeIsolated`).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SocketTasksSourceDeliveryTests {
    struct Delivered: Sendable, Equatable {
        var seq: UInt64
        var onMain: Bool
    }

    @Test func ownerEventsReachTheSinkOnTheMainThreadInOrder() async throws {
        let owner = try TasksOwnerSocket()
        defer { owner.close() }
        let source = SocketTasksSource(path: owner.path)
        let (delivered, deliver) = AsyncStream.makeStream(of: Delivered.self, bufferingPolicy: .bufferingNewest(16))
        source.start { event in
            if case .event(let change) = event { deliver.yield(Delivered(seq: change.seq, onMain: Thread.isMainThread)) }
        }
        defer { source.stop() }
        // The source connected in `start` (the listen backlog took it), so the accept is immediate.
        let peer = try owner.accept(within: 10)
        defer { Darwin.close(peer) }
        let lines = (1...3).map { seq in
            #"{"event":{"seq":\#(seq),"tx":"t\#(seq)","kind":"task.remove","change":{"type":"remove","entity":"task","id":"x"}}}"# + "\n"
        }
        // One write per line: the source may read them in one batch or several; the order holds either way.
        for line in lines { owner.write(Data(line.utf8), to: peer) }
        var iterator = delivered.makeAsyncIterator()
        var seen: [Delivered] = []
        while seen.count < lines.count, let next = await iterator.next() { seen.append(next) }
        #expect(seen == (1...3).map { Delivered(seq: UInt64($0), onMain: true) })
    }
}

/// A listening unix socket standing in for `cmux task serve`.
private nonisolated final class TasksOwnerSocket {
    let path: String
    private let descriptor: Int32

    init() throws {
        path = NSTemporaryDirectory() + "tasks-\(UUID().uuidString.prefix(8)).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
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
    }

    /// The source's connection, or a throw after `seconds`.
    func accept(within seconds: Int32) throws -> Int32 {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&entry, 1, seconds * 1000) == 1 else { throw POSIXError(.ETIMEDOUT) }
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { throw POSIXError(.ECONNABORTED) }
        return peer
    }

    /// Writes `data` to `peer` (a few bytes: the socket buffer takes them at once).
    func write(_ data: Data, to peer: Int32) {
        _ = data.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
    }

    func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}
