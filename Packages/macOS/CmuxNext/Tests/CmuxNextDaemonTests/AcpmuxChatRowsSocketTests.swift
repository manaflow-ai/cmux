import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextAgentList

/// Weak references to every handle a host made, to see one let go.
private final class Handles: Sendable {
    private final class Weak: @unchecked Sendable { weak var client: AcpmuxClient? } // crash-allow: test-only box, written once before it is shared
    private let all = Mutex<[Weak]>([])
    var make: @Sendable () -> AcpmuxClient {
        { [self] in
            let client = AcpmuxClient(surfaces: ["chat"])
            let box = Weak()
            box.client = client
            all.withLock { $0.append(box) }
            return client
        }
    }
    var count: Int { all.withLock { $0.count } }
    var live: Int { all.withLock { $0.filter { $0.client != nil }.count } }
}

/// A host on a real socket to a daemon of this test process.
private func socketHost(_ daemon: ChatDaemonSocket, handles: Handles, receiver: ChatRowsReceiver) -> AcpmuxChatRowsHost {
    let host = AcpmuxChatRowsHost(socketPath: daemon.path, deliver: receiver.deliver, makeClient: handles.make, connector: .socket)
    receiver.attach(host)
    return host
}

@Suite("AcpmuxChatRowsSocketTests", .serialized)
struct AcpmuxChatRowsSocketTests {
    @Test("a page that holds taken for 2 s while 10 MiB arrive: one batch held, the socket not read, no call, no timer")
    func heldPageReadsNothing() async throws {
        let opsCount = 10 * 1024
        let text = String(repeating: "x", count: 960)
        let stream: Data = {
            var bytes = ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10)
            for seq in 11..<(11 + opsCount) { bytes.append(ChatWire.op(seq, text: text)) }
            return bytes
        }()
        try #require(stream.count >= 10 << 20)
        let daemon = try ChatDaemonSocket { _ in (stream, false) }
        defer { daemon.stop() }
        let handles = Handles()
        let receiver = ChatRowsReceiver()
        receiver.hold(true)
        let host = socketHost(daemon, handles: handles, receiver: receiver)
        #expect(await host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        #expect(await eventually { !receiver.batches.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        let driver = try #require(await host.snapshotForTesting().driver)
        let before = await host.snapshotForTesting().counters
        let heldBefore = await driver.heldForTesting()
        let writtenBefore = daemon.written(0)
        try await Task.sleep(for: .seconds(2))
        let after = await host.snapshotForTesting().counters
        let heldAfter = await driver.heldForTesting()
        print("v2.pr06 held page: daemon wrote \(daemon.written(0)) of \(stream.count) bytes; driver holds batch \(heldAfter.pending), deferred change \(heldAfter.deferred), unread \(heldAfter.input); reads \(heldAfter.reads); host \(after)")
        #expect(receiver.batches.count == 1)
        #expect(after == before, "no wakeup, batch, call or timer while the page holds taken")
        #expect(after.bridgeCalls == 1 && after.timersArmed == 0)
        #expect(heldAfter.reads == heldBefore.reads, "the socket is not read")
        #expect(daemon.written(0) == writtenBefore)
        #expect(daemon.written(0) < stream.count)
        #expect(heldAfter.pending <= AcpmuxChatRowsHost.maxBatchBytes, "one batch")
        #expect(heldAfter.input <= AcpmuxChatRowsHost.maxBatchBytes, "at most one read the core has not taken")
        #expect(heldAfter.deferred <= 2 << 10, "the one change the batch could not hold")

        // Taken: delivery goes on, nothing lost and nothing twice.
        receiver.hold(false)
        host.taken(batch: try #require(receiver.batches.last?.batch))
        #expect(await eventually(60) { receiver.rowIds.count >= 10 + opsCount })
        #expect(receiver.rowIds == Array(1..<(11 + opsCount)))
        let counters = await host.snapshotForTesting().counters
        #expect(counters.timersArmed == 0)
        print("v2.pr06 held page: then \(counters.bridgeCalls) batches for \(opsCount) ops")
        host.pageGone()
    }

    @Test("page gone: unsub on the wire, the connection closed, the handle freed; shown again, one sub and one window")
    func pageGone() async throws {
        let first = ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10)
        let daemon = try ChatDaemonSocket { _ in (first, false) }
        defer { daemon.stop() }
        let handles = Handles()
        let receiver = ChatRowsReceiver()
        var host: AcpmuxChatRowsHost? = socketHost(daemon, handles: handles, receiver: receiver)
        #expect(await host?.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        #expect(await eventually { receiver.rowIds.count == 10 })
        #expect(daemon.count("\"method\":\"sub\"", in: 0) == 1)
        host?.pageGone()
        #expect(await eventually { daemon.count("\"method\":\"unsub\"", in: 0) == 1 }, "unsub on the wire")
        #expect(await eventually { daemon.clientClosed(0) }, "the connection closed")
        #expect(await eventually { handles.live == 0 }, "the handle freed")

        // The next document opens again, on a new handle and connection: one sub, one window.
        let again = ChatRowsReceiver()
        host = socketHost(daemon, handles: handles, receiver: again)
        #expect(await host?.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        #expect(await eventually { again.rowIds.count == 10 })
        // First proof that the driver read every byte the daemon wrote, so nothing is left in the
        // socket; then a barrier, not a wait: the driver's turn on what it read, then the host's turn.
        let driver = try #require(await host?.snapshotForTesting().driver)
        #expect(await eventually { await driver.heldForTesting().bytes == first.count && daemon.written(1) == first.count })
        await driver.flushForTesting()
        _ = await host?.snapshotForTesting()
        #expect(daemon.connections == 2 && handles.count == 2)
        #expect(daemon.count("\"method\":\"sub\"", in: 1) == 1)
        #expect(again.kinds().filter { $0 == "chatWindow" }.count == 1)
        host?.pageGone()
    }

    @Test("a drop in the middle of the stream and a reconnect: no event but the changes that follow, no row twice")
    func dropAndReconnect() async throws {
        let daemon = try ChatDaemonSocket { index in
            switch index {
            case 0:
                var bytes = ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10)
                for seq in 11...20 { bytes.append(ChatWire.op(seq)) }
                return (bytes, true)
            default:
                var bytes = ChatWire.reopening
                for seq in 21...29 { bytes.append(ChatWire.op(seq, replay: "replay")) }
                bytes.append(ChatWire.op(30, replay: "end"))
                bytes.append(ChatWire.op(31))
                return (bytes, false)
            }
        }
        defer { daemon.stop() }
        let handles = Handles()
        let receiver = ChatRowsReceiver()
        let host = socketHost(daemon, handles: handles, receiver: receiver)
        #expect(await host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        #expect(await eventually(15) { receiver.rowIds.count >= 31 })
        #expect(receiver.rowIds == Array(1...31), "no row twice, none lost")
        #expect(daemon.connections == 2 && handles.count == 1, "the same handle reconnected")
        let kinds = receiver.kinds()
        #expect(kinds.filter { $0 == "chatWindow" }.count == 1)
        #expect(Set(kinds).isSubset(of: ["chatError", "chatWindow", "chatOp", "chatResumeEnd"]))
        #expect(kinds.filter { $0 == "chatError" }.count == 1, "only the recorded not_ready")
        #expect(await host.snapshotForTesting().counters.timersArmed == 1, "one backoff")
        print("v2.pr06 drop: \(receiver.batches.count) batches, kinds \(kinds)")
        host.pageGone()
    }
}
