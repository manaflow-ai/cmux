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

    @Test("a pane hidden from its open (a covered window) draws its chat: the first window goes at once, its rows go on (cmux#44964)")
    func hiddenPaneDrawsItsChat() async throws {
        let fed = FedChatRowsHost(hiddenInterval: 0.05)
        // A New Tab chat in a window behind another app's: hidden before its first open.
        fed.host.setHidden(true)
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        try await fed.feed(ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds == Array(1...10) }, "the page waits on its first window: it goes while hidden")
        // The agent's answer and the turn's end: v1 hands a hidden page these too, so the chat
        // never shows Thinking with nothing under it while acpmux has the turn.
        try await fed.feed(ChatWire.op(11, text: "pong"), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds == Array(1...11) }, "a hidden page's rows go on, at the hidden pace")
        try await fed.feed(ChatWire.op(12), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds == Array(1...12) }, "and the sub reads on: a hidden page's taken is acknowledged")
    }

    /// The core's refusal of `rows.1`'s sub, as the recorded stream's `not_ready` (a kind-8 frame).
    private static let refused = ChatWire.frame(8, "{\"code\":\"not_ready\",\"method\":\"sub\",\"sid\":\"rows.1\"}")

    @Test("hidden, a chatError after an earlier call goes at once: the page waits on it (cmux#44964)")
    func hiddenErrorAfterACallGoesAtOnce() async throws {
        // A long pace: a batch can reach the page in time only by skipping the wait.
        let fed = FedChatRowsHost(hiddenInterval: 600)
        fed.host.setHidden(true)
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        try await fed.feed(ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds == Array(1...10) }, "the first window goes while hidden")
        try await fed.feed(Self.refused, chunk: 1 << 20)
        #expect(await eventually(2) { fed.receiver.kinds().filter { $0 == "chatError" }.count == 2 },
                "the refusal reaches the hidden page within the interval")
    }

    @Test("shown then hidden again, a chatError goes at once: a deadline armed before the show does not hold it (cmux#44964)")
    func hiddenAgainErrorGoesAtOnce() async throws {
        let fed = FedChatRowsHost(hiddenInterval: 600)
        fed.host.setHidden(true)
        #expect(await fed.host.open(sid: "rows.1", request: ChatWire.open) == .success("rows.1"))
        try await fed.feed(ChatWire.opening + ChatWire.window(cursor: 10, ids: 1...10), chunk: 1 << 20)
        #expect(await eventually { fed.receiver.rowIds == Array(1...10) })
        // An op while hidden, within the pace: held, its deadline armed.
        try await fed.feed(ChatWire.op(11), chunk: 1 << 20)
        let driver = try #require(await fed.driver())
        await driver.flushForTesting()
        _ = await fed.host.snapshotForTesting()
        #expect(fed.receiver.rowIds == Array(1...10), "hidden: the op is held")
        fed.host.setHidden(false)
        #expect(await eventually { fed.receiver.rowIds == Array(1...11) }, "shown: the held op goes")
        fed.host.setHidden(true)
        try await fed.feed(Self.refused, chunk: 1 << 20)
        #expect(await eventually(2) { fed.receiver.kinds().filter { $0 == "chatError" }.count == 2 },
                "hidden again, the refusal reaches the page within the interval")
    }
}
