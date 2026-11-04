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
        }

        let state = Mutex(State())
        let isReadOnly = false

        init(log: [UInt64] = []) { state.withLock { $0.log = log } }

        func attach(_ page: AgentSessionPage, events handler: @escaping @Sendable (AgentSessionRemoteEvent) -> Void) async throws -> Data {
            let (fails, hook) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
                state.attaches.append(page)
                state.handler = handler
                state.detached = false
                return (state.attachFails, state.onAttach)
            }
            if fails { throw AgentSessionRemoteError(code: "link.down", message: "no direct link") }
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
        try await Task.sleep(for: .milliseconds(50))
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
}
