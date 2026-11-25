import Foundation
import Testing
@testable import CmuxNextAgentList

/// The host contract's follow-ups to cmux#44353: a held batch outlives its driver, a read while a
/// batch is out stays unread, and the core's refusals of `subscribe_chat` keep their meaning.
@Suite("AcpmuxChatRowsFollowUpTests", .serialized)
struct AcpmuxChatRowsFollowUpTests {
    @Test("a batch held for a hidden pane survives its driver's replacement and goes when shown, with no ack owed")
    func replacedDriverKeepsHeldBatch() async throws {
        let fed = FedChatRowsHost()
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        try await fed.feed(ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds.count == 10 })
        fed.host.setHidden(true)
        try await fed.feed(ChatWire.op(11), chunk: 1 << 20)
        let old = try #require(await fed.driver())
        // A barrier, not a wait: the driver's turn hands the batch over, the host's turn holds it.
        await old.flushForTesting()
        _ = await fed.host.snapshotForTesting()
        #expect(fed.receiver.rowIds.count == 10, "hidden: the batch is held")

        // The socket fails on bad bytes and cannot reopen: the host makes a new driver.
        old.failForTesting()
        #expect(await eventually { await fed.driver().map { $0 !== old } ?? false }, "a new driver")
        fed.host.setHidden(false)
        #expect(await eventually { fed.receiver.rowIds == Array(1...11) }, "the core gave row 11 once; the page gets it")
        #expect(await fed.driver()?.heldForTesting().pending == 0, "the new driver owes no ack for the old batch")
    }

    @Test("a read that arrives while a batch is out (a reconnect's first read) stays unread until taken")
    func readWhileBatchOutStaysUnread() async throws {
        let fed = FedChatRowsHost()
        fed.receiver.hold(true)
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        try await fed.feed(ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.batches.count == 1 })
        let driver = try #require(await fed.driver())
        let op = ChatWire.op(11)
        driver.feedForTesting(op)
        // A barrier, not a wait: the driver's turn on the read.
        await driver.flushForTesting()
        let held = await driver.heldForTesting()
        #expect(held.input == op.count, "the core is not handed the read while the batch is out")
        fed.receiver.hold(false)
        fed.host.taken(batch: try #require(fed.receiver.batches.last?.batch))
        #expect(await eventually { fed.receiver.rowIds == Array(1...11) })
    }

    @Test("the core's refusal of a sub request of another shape is invalid params, not a name; nothing is held")
    func subscribeRefusalIsTheRequest() async throws {
        let fed = FedChatRowsHost()
        let refused = await fed.host.open(sid: "rows.1", request: ChatWire.request(["sid": "rows.1", "chat": "chat-a", "anchor": 5]))
        guard case .failure(let refusal) = refused else {
            Issue.record("the core took an anchor of another shape: \(refused)")
            return
        }
        #expect(refusal.rawValue == "cmux.protocol.invalid_params")
        #expect(await fed.host.snapshotForTesting().sids.isEmpty)
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"), "the sid is free")
    }
}
