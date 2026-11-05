import Foundation
import CmuxNextCompat
import Testing
@testable import CmuxNextAgentPane

/// A Cloud chat streams over the relay first and moves to the machine's direct link once it is up
/// (cmuxterm-hq#7086, lane c). The move must not drop or repeat a record or a prompt, and a direct
/// link that never comes up, or drops later, must leave the chat working over the relay.
@Suite(.serialized)
struct AgentSessionCarrierSwitchTests {
    /// One carrier's side of the chat: a session log it pages from, pushes the test makes, and
    /// prompts that can be held in flight.
    nonisolated final class Carrier: AgentSessionRemoteClient {
        struct State {
            var handler: (@Sendable (AgentSessionRemoteEvent) -> Void)?
            var log: [UInt64] = []
            var pageLimit = Int.max
            var attachFails = false
            var attaches: [AgentSessionPage] = []
            var prompts: [String] = []
            var holdPrompts = false
            var heldPrompts: [CheckedContinuation<Void, Never>] = []
            var closed = false
            var detached = false
            var onAttach: (@Sendable () -> Void)?
            /// The next attach waits here until ``releaseAttach()``.
            var holdAttach = false
            var heldAttach: CheckedContinuation<Void, Never>?
        }

        let state = Mutex(State())
        let isReadOnly: Bool

        init(log: [UInt64] = [], readOnly: Bool = false) {
            isReadOnly = readOnly
            state.withLock { $0.log = log }
        }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            let (fails, hook) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
                state.attaches.append(page)
                state.handler = handler
                state.detached = false
                return (state.attachFails, state.onAttach)
            }
            if fails { throw AgentSessionRemoteError(code: "link.down", message: "no direct link") }
            if state.withLock({ $0.holdAttach }) {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    state.withLock { $0.heldAttach = waiter }
                }
            }
            hook?()
            return answer(after: page.afterSeq)
        }

        func events(_ page: AgentSessionPage) async throws -> Data { answer(after: page.afterSeq) }

        private func answer(after: UInt64?) -> Data {
            let (log, limit) = state.withLock { ($0.log, $0.pageLimit) }
            let after = after ?? 0
            let rest = log.filter { $0 > after }
            let page = Array(rest.prefix(limit))
            let events = page.map { ["seq": $0] }
            return RemoteAcpmuxWire.json(["events": events, "hasMore": rest.count > page.count, "lastSeq": log.last ?? 0])
        }

        func prompt(id: String, text: String) async throws -> Data {
            state.withLock { $0.prompts.append(id) }
            if state.withLock({ $0.holdPrompts }) {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    state.withLock { $0.heldPrompts.append(waiter) }
                }
            }
            return RemoteAcpmuxWire.json(["prompt_id": id, "turn_id": "t-\(id)", "queued": false])
        }

        func cancel() async throws {}
        func permission(id: String, option: String, answers: Data?, annotations: Data?, decisionNonce: String?,
                        personDecision: String?) async throws {}
        func detach() async { state.withLock { $0.detached = true } }
        func close() async { state.withLock { $0.closed = true } }

        func push(_ seq: UInt64) {
            let handler = state.withLock { state -> (@Sendable (AgentSessionRemoteEvent) -> Void)? in
                if !state.log.contains(seq) { state.log.append(seq) }
                return state.handler
            }
            handler?(.record(Data(#"{"seq":\#(seq)}"#.utf8)))
        }

        func releaseAttach() {
            let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.holdAttach = false
                defer { state.heldAttach = nil }
                return state.heldAttach
            }
            held?.resume()
        }

        var attachHeld: Bool { state.withLock { $0.heldAttach != nil } }

        func end(_ reason: String) { state.withLock { $0.handler }?(.closed(reason)) }

        func releasePrompts() {
            let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.holdPrompts = false
                defer { state.heldPrompts = [] }
                return state.heldPrompts
            }
            for waiter in held { waiter.resume() }
        }

        var prompts: [String] { state.withLock { $0.prompts } }
        var heldCount: Int { state.withLock { $0.heldPrompts.count } }
    }

    /// What the page got.
    nonisolated final class Page: Sendable {
        let events = Mutex<[AgentSessionRemoteEvent]>([])
        var handler: @Sendable (AgentSessionRemoteEvent) -> Void { { event in self.events.withLock { $0.append(event) } } }
        var seqs: [UInt64] {
            events.withLock { $0 }.compactMap { event in
                if case .record(let data) = event { return AgentSessionCarrierSwitch.seq(of: data) }
                return nil
            }
        }
        var closes: Int {
            events.withLock { $0 }.filter { if case .closed = $0 { return true } else { return false } }.count
        }
    }

    static func until(_ condition: @Sendable () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func eachRecordReachesThePageOnceInOrderWhereverTheMoveFalls() async throws {
        let total: UInt64 = 12
        for k in UInt64(0)...total {
            let relay = Carrier()
            // The direct side already has records the relay has not pushed, more than one page of them.
            let direct = Carrier(log: Array(1...min(total, k + 4)))
            direct.state.withLock { $0.pageLimit = 2 }
            // The relay keeps pushing while the direct attach is under way.
            direct.state.withLock { state in
                state.onAttach = { if k + 1 <= total { relay.push(k + 1) } }
            }
            let chat = AgentSessionCarrierSwitch(fallback: relay)
            let page = Page()
            _ = try await chat.attach(AgentSessionPage(limit: 50), events: page.handler)
            for seq in stride(from: 1, through: k, by: 1) { relay.push(seq) }

            #expect(await chat.move(to: direct))
            // Late relay pushes after the cutover are not the chat's any more.
            if k + 2 <= total { relay.push(k + 2) }
            for seq in stride(from: k + 1, through: total, by: 1) { direct.push(seq) }

            #expect(page.seqs == Array(1...total), "move after seq \(k)")
            #expect(page.closes == 0)
            #expect(direct.state.withLock { $0.attaches.first?.afterSeq } == k)
            #expect(relay.state.withLock { $0.detached })
        }
    }

    @Test func aPromptInFlightFinishesOnTheRelayAndOneSentDuringTheMoveGoesDirectOnce() async throws {
        let relay = Carrier()
        let direct = Carrier()
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        _ = try await chat.attach(AgentSessionPage(), events: Page().handler)
        relay.state.withLock { $0.holdPrompts = true }
        let first = Task { try await chat.prompt(id: "a", text: "first") }
        await Self.until { relay.heldCount == 1 }

        let move = Task { await chat.move(to: direct) }
        await Self.until { chat.holding }
        let second = Task { try await chat.prompt(id: "b", text: "second") }
        await Self.until { chat.heldCalls == 1 }
        #expect(direct.prompts.isEmpty, "a prompt made during the cutover waits for it")

        relay.releasePrompts()
        _ = try await first.value
        #expect(await move.value)
        _ = try await second.value
        #expect(relay.prompts == ["a"])
        #expect(direct.prompts == ["b"])
    }

    @Test func callsThatDoNotFinishKeepTheChatOnTheRelay() async throws {
        let relay = Carrier()
        let direct = Carrier()
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        _ = try await chat.attach(AgentSessionPage(), events: Page().handler)
        relay.state.withLock { $0.holdPrompts = true }
        let first = Task { try await chat.prompt(id: "a", text: "first") }
        await Self.until { relay.heldCount == 1 }

        #expect(await chat.move(to: direct, drainLimit: .milliseconds(100)) == false)
        #expect(direct.state.withLock { $0.closed })
        #expect(!chat.moved)
        relay.releasePrompts()
        _ = try await first.value
        _ = try await chat.prompt(id: "b", text: "second")
        #expect(relay.prompts == ["a", "b"])
        #expect(direct.prompts.isEmpty)
    }

    @Test func aDirectLinkThatNeverComesUpLeavesTheChatOnTheRelay() async throws {
        let relay = Carrier()
        let direct = Carrier()
        direct.state.withLock { $0.attachFails = true }
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        _ = try await chat.attach(AgentSessionPage(), events: page.handler)
        relay.push(1)

        #expect(await chat.move(to: direct) == false)
        relay.push(2)
        _ = try await chat.prompt(id: "a", text: "hi")
        #expect(page.seqs == [1, 2])
        #expect(page.closes == 0)
        #expect(relay.prompts == ["a"])
        #expect(!relay.state.withLock { $0.detached })
    }

    @Test func aDirectLinkThatDropsMovesTheChatBackToTheRelayWithNoGap() async throws {
        let relay = Carrier()
        let direct = Carrier()
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        _ = try await chat.attach(AgentSessionPage(), events: page.handler)
        relay.push(1)
        #expect(await chat.move(to: direct))
        direct.push(2)
        direct.push(3)
        // The relay's log has what the direct attachment streamed, plus one record after the drop.
        relay.state.withLock { $0.log = [1, 2, 3, 4] }

        direct.end("link.down")
        await Self.until { relay.state.withLock { $0.attaches.count } == 2 }
        await Self.until { page.seqs.count == 4 }
        #expect(relay.state.withLock { $0.attaches.last?.afterSeq } == 3)
        #expect(page.seqs == [1, 2, 3, 4])
        #expect(page.closes == 0)
        #expect(direct.state.withLock { $0.closed })
        _ = try await chat.prompt(id: "a", text: "after")
        #expect(relay.prompts == ["a"])
        #expect(!chat.moved)
    }

    @Test func theRelaysEndBeforeAnyMoveEndsThePagesAttachment() async throws {
        let relay = Carrier()
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        _ = try await chat.attach(AgentSessionPage(), events: page.handler)
        relay.end("lagged")
        #expect(page.closes == 1)
        #expect(await chat.move(to: Carrier()) == false)
    }

    /// Codex review F1 (cmux#35770): a later `_acpmux/watch` re-attach (one transcript record) must
    /// not narrow what a move replays.
    @Test func aWatchReattachDoesNotNarrowTheMove() async throws {
        let relay = Carrier()
        let direct = Carrier(log: [1, 2])
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        _ = try await chat.attach(AgentSessionPage(limit: 50, kinds: ["transcript", "tool"]), events: Page().handler)
        _ = try await chat.attach(RemoteAcpmuxWire.watchPage, events: Page().handler)
        #expect(await chat.move(to: direct))
        #expect(direct.state.withLock { $0.attaches.first?.kinds } == ["transcript", "tool"])
    }

    /// Codex review F2: records the page read forward through `events` are not replayed by a move.
    @Test func recordsPagedForwardAreNotReplayedByAMove() async throws {
        let relay = Carrier()
        let direct = Carrier(log: [1, 2, 3, 4])
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        _ = try await chat.attach(AgentSessionPage(afterSeq: 0), events: page.handler)
        // Records 1-3 reach the page through a forward events read, not as pushes.
        relay.state.withLock { $0.log = [1, 2, 3] }
        _ = try await chat.events(AgentSessionPage(afterSeq: 0))
        #expect(await chat.move(to: direct))
        #expect(direct.state.withLock { $0.attaches.first?.afterSeq } == 3)
        #expect(page.seqs == [4])
    }

    /// Codex review F3: no move starts while the chat is on its way back to the relay.
    @Test func noMoveStartsDuringAFallBack() async throws {
        let relay = Carrier()
        let direct = Carrier()
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        _ = try await chat.attach(AgentSessionPage(), events: Page().handler)
        #expect(await chat.move(to: direct))
        relay.state.withLock { $0.holdAttach = true }
        direct.end("link.down")
        await Self.until { relay.attachHeld }
        #expect(relay.attachHeld, "the fall-back is re-attaching the relay")

        let second = Carrier()
        #expect(await chat.move(to: second) == false)
        #expect(second.state.withLock { $0.attaches.isEmpty })

        relay.releaseAttach()
        await Self.until { !chat.holding }
        _ = try await chat.prompt(id: "a", text: "after")
        #expect(relay.prompts == ["a"])
        #expect(await chat.move(to: Carrier()), "a move works again once the fall-back is done")
    }

    /// Codex review F4: read-only follows the client that carries the chat.
    @Test func readOnlyFollowsTheCarrier() async throws {
        let relay = Carrier(readOnly: true)
        let direct = Carrier(readOnly: false)
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        _ = try await chat.attach(AgentSessionPage(), events: Page().handler)
        #expect(chat.isReadOnly)
        #expect(await chat.move(to: direct))
        #expect(!chat.isReadOnly)
    }

    /// Codex re-review of cmux#35770 at c720068f: a forward attach that stops short of the log's head
    /// (`hasMore`) covers only through its own records (`pageThrough`), not through `lastSeq`. A move
    /// must re-attach from there, or the records between are skipped for good.
    @Test func aShortForwardAttachCoversOnlyItsOwnRecords() async throws {
        let relay = Carrier(log: [1, 2, 3, 4, 5])
        relay.state.withLock { $0.pageLimit = 2 }
        let direct = Carrier(log: [1, 2, 3, 4, 5])
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        // The page holds 1-2 from the attach answer and has not read on yet.
        _ = try await chat.attach(AgentSessionPage(afterSeq: 0, limit: 2), events: page.handler)
        #expect(await chat.move(to: direct))
        #expect(direct.state.withLock { $0.attaches.first?.afterSeq } == 2)
        #expect(page.seqs == [3, 4, 5])
    }

    @Test func coveredFollowsAcpmuxsPageThroughRule() {
        let json = { (object: [String: Any]) in RemoteAcpmuxWire.json(object) }
        let partial = json(["events": [["seq": 1], ["seq": 2]], "hasMore": true, "lastSeq": 9])
        let told = json(["events": [["seq": 1]], "hasMore": true, "lastSeq": 9, "pageThrough": 1])
        let whole = json(["events": [["seq": 8], ["seq": 9]], "hasMore": false, "lastSeq": 9])
        #expect(AgentSessionCarrierSwitch.covered(partial, by: AgentSessionPage(afterSeq: 0)) == 2)
        #expect(AgentSessionCarrierSwitch.covered(told, by: AgentSessionPage(afterSeq: 0)) == 1)
        #expect(AgentSessionCarrierSwitch.covered(whole, by: AgentSessionPage(afterSeq: 7)) == 9)
        // The newest page (no cursor) holds through the head; an older page only through its own.
        #expect(AgentSessionCarrierSwitch.covered(partial, by: AgentSessionPage(limit: 2)) == 9)
        #expect(AgentSessionCarrierSwitch.covered(partial, by: AgentSessionPage(beforeSeq: 3)) == 2)
    }

    /// Codex re-review of cmux#35770 at c74aa8f3, F1, and at 54f1272e, F1: a refused re-attach keeps
    /// the attachment the page had live, whichever handler the client then pushes on. The real client
    /// keeps the new handler after a refusal; one cancelled before sending keeps the old one.
    @Test(arguments: [true, false])
    func aRefusedReattachKeepsTheLiveAttachment(clientKeepsNewHandler: Bool) async throws {
        let relay = Carrier()
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        _ = try await chat.attach(AgentSessionPage(), events: page.handler)
        relay.push(1)
        let old = relay.state.withLock { $0.handler }
        relay.state.withLock { $0.attachFails = true }
        await #expect(throws: AgentSessionRemoteError.self) {
            _ = try await chat.attach(AgentSessionPage(afterSeq: 1), events: page.handler)
        }
        // The fake installs the new handler before it refuses, as AgentSessionAttachClient does.
        if !clientKeepsNewHandler { relay.state.withLock { $0.handler = old } }
        relay.push(2)
        #expect(page.seqs == [1, 2])
    }

    /// Codex re-review at 54f1272e, F2: a fall-back waits for calls still running on the direct client,
    /// so a prompt made during it never reaches the relay ahead of an older one.
    @Test func aFallBackWaitsForDirectCallsInFlight() async throws {
        let relay = Carrier()
        let direct = Carrier()
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        _ = try await chat.attach(AgentSessionPage(), events: Page().handler)
        #expect(await chat.move(to: direct))
        direct.state.withLock { $0.holdPrompts = true }
        let first = Task { try await chat.prompt(id: "a", text: "first") }
        await Self.until { direct.heldCount == 1 }

        direct.end("link.down")
        await Self.until { relay.state.withLock { $0.attaches.count } == 2 }
        let second = Task { try await chat.prompt(id: "b", text: "second") }
        await Self.until { chat.heldCalls == 1 }
        #expect(relay.prompts.isEmpty, "the newer prompt waits for the one still running on the direct link")

        direct.releasePrompts()
        _ = try await first.value
        _ = try await second.value
        #expect(direct.prompts == ["a"])
        #expect(relay.prompts == ["b"])
    }

    /// F2: a watch answer never moves the cursor, since the page never gets its record.
    @Test func aWatchAnswerDoesNotMoveTheCursor() async throws {
        let relay = Carrier()
        let direct = Carrier(log: [1, 2, 3])
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        _ = try await chat.attach(AgentSessionPage(afterSeq: 0), events: page.handler)
        relay.state.withLock { $0.log = [1, 2, 3] }
        _ = try await chat.attach(RemoteAcpmuxWire.watchPage, events: page.handler)
        #expect(await chat.move(to: direct))
        #expect(direct.state.withLock { $0.attaches.first?.afterSeq } == 0)
        #expect(page.seqs == [1, 2, 3])
    }

    /// Codex review of cmux#35770 at 6dddfc8a, follow-up F1: only the wire's own watch read is a
    /// listing. A page's attach that asks for the same records still sets the re-attach page and
    /// moves the cursor.
    @Test func anAttachShapedLikeAWatchIsStillThePagesOwn() async throws {
        let relay = Carrier(log: [1])
        let direct = Carrier(log: [1, 2])
        let chat = AgentSessionCarrierSwitch(fallback: relay)
        let page = Page()
        _ = try await chat.attach(AgentSessionPage(limit: 1, kinds: ["transcript"]), events: page.handler)
        #expect(await chat.move(to: direct))
        #expect(direct.state.withLock { $0.attaches.first?.afterSeq } == 1)
        #expect(direct.state.withLock { $0.attaches.first?.kinds } == ["transcript"])
        #expect(page.seqs == [2])
    }
}
