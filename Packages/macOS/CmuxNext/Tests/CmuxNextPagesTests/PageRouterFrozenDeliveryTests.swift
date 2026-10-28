import CmuxNextSettings
@testable import CmuxNextPages
import Testing

/// The router hold (webui-DESIGN.md "Lifecycle"): while a page is hidden or frozen,
/// no event envelope reaches its script pipeline; each stream keeps what its
/// ``PageFrozenDelivery`` says; release sends the rest in arrival and `seq` order; each drop calls
/// `eventDeliveryDropped` once; a built-in command or a host call thaws the page first, then goes
/// through, so no page call waits out a deadline because of a freeze.
@MainActor
struct PageRouterFrozenDeliveryTests {
    static let descriptor = PageDescriptor(id: "cmux.held-test", resource: "held-test", processGroup: .solo,
                                           namespaces: ["cmux.held."])

    /// What reached the page and what the lifecycle heard, in one order.
    final class Log {
        var entries: [String] = []
        var sent: [JSONValue] = []

        /// Every event that reached the page, a release batch (`evs`) unpacked in its order.
        var events: [JSONValue] {
            sent.flatMap { envelope -> [JSONValue] in
                switch envelope["t"]?.stringValue {
                case "ev": [envelope]
                case "evs": envelope["events"]?.arrayValue ?? []
                default: []
                }
            }
        }
    }

    final class Lifecycle: PageDeliveryLifecycle {
        let log: Log
        var halfFull = 0

        init(log: Log) { self.log = log }

        func thawForDelivery() { log.entries.append("thaw") }
        func orderedDeliveryHalfFull() {
            halfFull += 1
            log.entries.append("halfFull")
        }
    }

    /// One event stream per name, each with its declared policy; records every drop it hears.
    final class StreamProvider: PageProvider {
        let policies: [String: PageFrozenDelivery]
        var emitters: [String: @MainActor (JSONValue) -> Void] = [:]
        var dropped: [JSONValue] = []
        /// Events sent from inside `subscribe` (a provider that sends its current state at once).
        var eventsDuringSubscribe = 0
        var eventsAfterSubscribeReply = false

        init(_ policies: [String: PageFrozenDelivery]) { self.policies = policies }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            emitters[stream] = onEvent
            for n in 0..<eventsDuringSubscribe { onEvent(["n": .number(Double(n))]) }
            return PageSubscription(frozenDelivery: policies[stream] ?? .ordered) {}
        }

        func eventDeliveryDropped(stream: String, data: JSONValue, publicationID: UInt64?) {
            dropped.append(data)
        }

        func emit(_ stream: String, _ numbers: Range<Int>) {
            for n in numbers { emitters[stream]?(["n": .number(Double(n))]) }
        }
    }

    private func makeRouter(_ provider: StreamProvider) -> (PageRouter, Lifecycle) {
        let router = PageRouter(descriptor: Self.descriptor, routes: [PageRoute(prefix: "cmux.held.", provider: provider)])
        let lifecycle = Lifecycle(log: Log())
        router.lifecycle = lifecycle
        router.send = { [log = lifecycle.log] envelope in
            log.sent.append(envelope)
            log.entries.append("send:\(envelope["t"]?.stringValue ?? "")")
        }
        return (router, lifecycle)
    }

    private func subscribe(_ router: PageRouter, _ stream: String) async -> Double {
        let reply = await router.handle(["t": "sub", "id": 1, "stream": .string(stream)])
        #expect(reply["t"]?.stringValue == "ok")
        return reply["value"]?["sub"]?.doubleValue ?? 0
    }

    private func numbers(_ events: [JSONValue]) -> [Double] { events.compactMap { $0["data"]?["n"]?.doubleValue } }
    private func seqs(_ events: [JSONValue]) -> [Double] { events.compactMap { $0["seq"]?.doubleValue } }
    private func gaps(_ events: [JSONValue]) -> [Bool] { events.map { $0["gap"] != nil } }

    @Test func heldEventsNeverReachThePipelineAndReleaseKeepsSeqOrder() async {
        let provider = StreamProvider(["cmux.held.log": .ordered])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.log")
        provider.emit("cmux.held.log", 0..<1)
        router.holdDelivery()
        provider.emit("cmux.held.log", 1..<4)
        #expect(lifecycle.log.events.count == 1, "0 envelopes while held")
        #expect(router.heldEventCount == 3)
        router.releaseDelivery()
        #expect(numbers(lifecycle.log.events) == [0, 1, 2, 3])
        #expect(seqs(lifecycle.log.events) == [1, 2, 3, 4])
        #expect(gaps(lifecycle.log.events) == [false, false, false, false])
        provider.emit("cmux.held.log", 4..<5)
        #expect(seqs(lifecycle.log.events) == [1, 2, 3, 4, 5], "live again after release")
        #expect(provider.dropped.isEmpty)
    }

    @Test func latestKeepsTheNewestAndReportsEachDropOnce() async {
        let provider = StreamProvider(["cmux.held.state": .latest])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.state")
        router.holdDelivery()
        provider.emit("cmux.held.state", 0..<4)
        #expect(numbers(provider.dropped) == [0, 1, 2])
        router.releaseDelivery()
        #expect(numbers(lifecycle.log.events) == [3])
        #expect(seqs(lifecycle.log.events) == [1])
        #expect(gaps(lifecycle.log.events) == [false], "a state stream needs no resync")
    }

    @Test func resyncMarksAGapOnlyWhenItDropped() async {
        let provider = StreamProvider(["cmux.held.deltas": .resync])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.deltas")
        router.holdDelivery()
        provider.emit("cmux.held.deltas", 0..<1)
        router.releaseDelivery()
        router.holdDelivery()
        provider.emit("cmux.held.deltas", 1..<4)
        router.releaseDelivery()
        #expect(numbers(lifecycle.log.events) == [0, 3])
        #expect(seqs(lifecycle.log.events) == [1, 2])
        #expect(gaps(lifecycle.log.events) == [false, true])
        #expect(numbers(provider.dropped) == [1, 2])
    }

    @Test func queueKeepsTheNewestLimitAndMarksAGap() async {
        let provider = StreamProvider(["cmux.held.feed": .queue(2)])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.feed")
        router.holdDelivery()
        provider.emit("cmux.held.feed", 0..<5)
        #expect(numbers(provider.dropped) == [0, 1, 2])
        router.releaseDelivery()
        #expect(numbers(lifecycle.log.events) == [3, 4])
        #expect(seqs(lifecycle.log.events) == [1, 2])
        #expect(gaps(lifecycle.log.events) == [true, false])
    }

    @Test func releaseKeepsArrivalOrderAcrossStreams() async {
        let provider = StreamProvider(["cmux.held.a": .ordered, "cmux.held.b": .ordered])
        let (router, lifecycle) = makeRouter(provider)
        let a = await subscribe(router, "cmux.held.a")
        let b = await subscribe(router, "cmux.held.b")
        router.holdDelivery()
        for n in 0..<3 {
            provider.emit("cmux.held.a", (2 * n)..<(2 * n + 1))
            provider.emit("cmux.held.b", (2 * n + 1)..<(2 * n + 2))
        }
        #expect(lifecycle.log.sent.isEmpty)
        router.releaseDelivery()
        let events = lifecycle.log.events
        #expect(numbers(events) == [0, 1, 2, 3, 4, 5])
        #expect(events.compactMap { $0["sub"]?.doubleValue } == [a, b, a, b, a, b])
        #expect(seqs(events) == [1, 1, 2, 2, 3, 3])
    }

    /// A busy `.ordered` stream on a hidden page: at half full the lifecycle hears it (the page
    /// leaves Frozen) and the router sends what it held in one batch, then holds again. Three
    /// half-fulls in one hold report three times and the hold never keeps more than half full.
    @Test func orderedNeverDropsAndStaysBoundedWhileHeld() async {
        let provider = StreamProvider(["cmux.held.turns": .ordered])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.turns")
        let half = PageFrozenDelivery.orderedHalfFull
        router.holdDelivery()
        provider.emit("cmux.held.turns", 0..<(half - 1))
        #expect(lifecycle.halfFull == 0)
        #expect(lifecycle.log.sent.isEmpty)
        var most = 0
        for n in (half - 1)..<(3 * half + 10) {
            provider.emit("cmux.held.turns", n..<(n + 1))
            most = max(most, router.heldEventCount)
        }
        #expect(most < half, "the hold stays bounded")
        #expect(lifecycle.halfFull == 3, "each fill is reported")
        #expect(lifecycle.log.entries == ["halfFull", "send:evs", "halfFull", "send:evs", "halfFull", "send:evs"])
        #expect(router.deliveryHeld, "the page is still hidden")
        #expect(router.heldEventCount == 10)
        router.releaseDelivery()
        #expect(provider.dropped.isEmpty)
        #expect(lifecycle.log.events.count == 3 * half + 10)
        #expect(seqs(lifecycle.log.events) == (1...(3 * half + 10)).map { Double($0) })
        #expect(numbers(lifecycle.log.events) == (0..<(3 * half + 10)).map { Double($0) })
    }

    /// A release is one batch: one send for any number of held events, so the show turn does not
    /// evaluate a script per event.
    @Test func releaseIsOneSend() async {
        let provider = StreamProvider(["cmux.held.a": .ordered, "cmux.held.b": .queue(100)])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.a")
        _ = await subscribe(router, "cmux.held.b")
        router.holdDelivery()
        provider.emit("cmux.held.a", 0..<500)
        provider.emit("cmux.held.b", 0..<500)
        router.releaseDelivery()
        #expect(lifecycle.log.entries == ["send:evs"])
        #expect(lifecycle.log.events.count == 600)
    }

    /// A full `.queue(limit)` drops one event per event (oldest first) and keeps exactly `limit`.
    @Test func aFullQueueKeepsItsLimit() async {
        let provider = StreamProvider(["cmux.held.feed": .queue(64)])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.feed")
        router.holdDelivery()
        provider.emit("cmux.held.feed", 0..<1_000)
        #expect(router.heldEventCount == 64)
        #expect(numbers(provider.dropped) == (0..<936).map { Double($0) })
        router.releaseDelivery()
        #expect(numbers(lifecycle.log.events) == (936..<1_000).map { Double($0) })
        #expect(gaps(lifecycle.log.events) == [true] + Array(repeating: false, count: 63))
    }

    /// Cmd-F on a frozen page: the command thaws it in the same turn, then reaches the page past
    /// the hold; the held events stay held.
    @Test func aCommandToAFrozenPageThawsThenDelivers() async {
        let provider = StreamProvider(["cmux.held.log": .ordered])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, PageNativeOp.pageCommand)
        _ = await subscribe(router, "cmux.held.log")
        router.holdDelivery()
        provider.emit("cmux.held.log", 0..<2)
        #expect(router.publishCommand(PageNativeOp.focusContent))
        #expect(lifecycle.log.entries == ["thaw", "send:ev"])
        #expect(lifecycle.log.events.first?["data"]?["command"]?.stringValue == PageNativeOp.focusContent)
        #expect(router.heldEventCount == 2)
    }

    /// A host call (the Home switch's selection read) to a frozen page thaws it before the call
    /// envelope goes out, and the page answers: no deadline can fire because of the freeze.
    @Test func aHostCallToAFrozenPageThawsFirstAndIsAnswered() async throws {
        let provider = StreamProvider([:])
        let (router, lifecycle) = makeRouter(provider)
        router.send = { [log = lifecycle.log] envelope in
            log.sent.append(envelope)
            log.entries.append("send:\(envelope["t"]?.stringValue ?? "")")
            guard envelope["t"]?.stringValue == "call", let id = envelope["id"] else { return }
            Task { @MainActor in _ = await router.handle(["t": "ok", "id": id, "value": ["selected": "a"]]) }
        }
        router.holdDelivery()
        let value = try await router.callPage("cmux.held.selection", params: .object([:]))
        #expect(value["selected"]?.stringValue == "a")
        #expect(lifecycle.log.entries == ["thaw", "send:call"])
    }

    /// A provider that sends its state from inside `subscribe` while the page is hidden: the events
    /// are kept whole until the subscription names its policy, then trimmed by it.
    @Test func eventsHeldWhileSubscribeRunsTakeThePolicyItNames() async {
        let provider = StreamProvider(["cmux.held.state": .latest])
        provider.eventsDuringSubscribe = 3
        provider.eventsAfterSubscribeReply = true
        let (router, lifecycle) = makeRouter(provider)
        router.holdDelivery()
        _ = await subscribe(router, "cmux.held.state")
        #expect(numbers(provider.dropped) == [0, 1])
        router.releaseDelivery()
        #expect(numbers(lifecycle.log.events) == [2])
    }

    /// Held events never reached the page: a reload or tab close reports each as dropped once
    /// (the agent provider requeues them), and none is sent.
    @Test func closeWhileHeldReportsEachHeldEventDroppedOnce() async {
        let provider = StreamProvider(["cmux.held.log": .ordered])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.log")
        router.holdDelivery()
        provider.emit("cmux.held.log", 0..<3)
        router.reset()
        #expect(numbers(provider.dropped) == [0, 1, 2])
        #expect(lifecycle.log.sent.isEmpty)
        #expect(router.deliveryHeld, "a hidden page that reloads stays held")
        router.releaseDelivery()
        #expect(lifecycle.log.sent.isEmpty)
        #expect(numbers(provider.dropped) == [0, 1, 2])
    }

    /// A pooled router handed to a new claim does not keep the old claim's hold: the new document's
    /// events reach it (its own lifecycle holds again if its page is hidden).
    @Test func rebindDropsTheOldClaimsHold() async {
        let provider = StreamProvider(["cmux.held.log": .ordered])
        let (router, lifecycle) = makeRouter(provider)
        _ = await subscribe(router, "cmux.held.log")
        router.holdDelivery()
        provider.emit("cmux.held.log", 0..<2)
        router.rebind(descriptor: Self.descriptor, routes: [PageRoute(prefix: "cmux.held.", provider: provider)])
        #expect(numbers(provider.dropped) == [0, 1])
        #expect(!router.deliveryHeld)
        _ = await subscribe(router, "cmux.held.log")
        provider.emit("cmux.held.log", 2..<3)
        #expect(numbers(lifecycle.log.events) == [2])
    }
}
