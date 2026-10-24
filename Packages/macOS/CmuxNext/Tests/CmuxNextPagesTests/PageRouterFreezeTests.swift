@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// While the hibernation keeps a cmux page frozen (perf-lead.md F3), no event goes into it and a
/// push does not thaw it. Before, every push into a hidden page thawed it and restarted its grace,
/// so a page the host kept feeding (a Settings list, Home's state) never froze. Each stream says
/// what its events are (``PageStreamFreezing``): its events fold into one per key for the thaw, so
/// the page is current the moment it thaws, with no new subscribe and no gap; only the person's
/// input to the page thaws it. A host call thaws it too.
@MainActor
struct PageRouterFreezeTests {
    /// A provider whose stream the test drives.
    private final class StreamProvider: PageProvider {
        let freezing: PageStreamFreezing
        var emit: ((JSONValue) -> Void)?
        var cancelled = 0

        init(_ freezing: PageStreamFreezing) {
            self.freezing = freezing
        }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue { .object([:]) }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            emit = onEvent
            return PageSubscription(freezing: freezing) { [weak self] in self?.cancelled += 1 }
        }
    }

    /// A router with one provider stream and the envelopes it sent, and a wake that thaws it.
    private final class Rig {
        let router: PageRouter
        var sent: [JSONValue] = []
        var wakes = 0

        init(_ provider: StreamProvider) {
            router = PageRouter(descriptor: PageDescriptor(id: "test.freeze", resource: "freeze", namespaces: ["test."]),
                                routes: [PageRoute(prefix: "test.", provider: provider)])
            router.send = { [unowned self] envelope in sent.append(envelope) }
        }

        func subscribe(_ stream: String, id: Int = 1) async -> UInt64? {
            let reply = await router.handle(["t": "sub", "id": .number(Double(id)), "stream": .string(stream)])
            return reply["value"]?["sub"]?.doubleValue.map { UInt64($0) }
        }

        func freeze() {
            router.freeze { [unowned self] in
                wakes += 1
                router.thaw()
            }
        }

        /// The `data` of each event sent, in order.
        var events: [JSONValue] { sent.filter { $0["t"]?.stringValue == "ev" }.compactMap { $0["data"] } }
    }

    @Test func aStateStreamHoldsOnlyItsNewestEventWhileFrozenAndSendsItAtTheThaw() async throws {
        let provider = StreamProvider(.newest)
        let rig = Rig(provider)
        _ = try #require(await rig.subscribe("test.state"))
        let emit = try #require(provider.emit)
        emit(["n": 1])
        #expect(rig.events == [["n": 1]])

        rig.freeze()
        emit(["n": 2])
        emit(["n": 3])
        #expect(rig.events == [["n": 1]], "an event went into a frozen page")
        #expect(rig.wakes == 0, "a state push thawed the page")
        #expect(rig.router.frozen.count == 1)
        #expect(provider.cancelled == 0) // the page keeps its subscription: no gap, no new subscribe

        rig.router.thaw()
        #expect(rig.events == [["n": 1], ["n": 3]])
        // Numbered on: the page's client drops a seq it has seen.
        #expect(rig.sent.last?["seq"]?.doubleValue == 2)
        emit(["n": 4])
        #expect(rig.events.last == ["n": 4])
    }

    @Test func keyedEventsKeepTheNewestOfEachKeyInTheOrderTheyCame() async throws {
        let provider = StreamProvider(.newest(by: { $0["kind"]?.stringValue }))
        let rig = Rig(provider)
        _ = try #require(await rig.subscribe("test.host"))
        let emit = try #require(provider.emit)
        rig.freeze()
        emit(["kind": "theme", "v": 1])
        emit(["kind": "header", "v": 1])
        emit(["kind": "theme", "v": 2])
        #expect(rig.events.isEmpty)

        rig.router.thaw()
        #expect(rig.events == [["kind": "header", "v": 1], ["kind": "theme", "v": 2]])
    }

    /// An event without a key (the person's input) cannot wait: it thaws the page, after which the
    /// held state goes first, then the event.
    @Test func anEventThatCannotWaitThawsThePageAfterTheHeldState() async throws {
        let provider = StreamProvider(.newest(by: { $0["kind"]?.stringValue == "action" ? nil : "state" }))
        let rig = Rig(provider)
        _ = try #require(await rig.subscribe("test.host"))
        let emit = try #require(provider.emit)
        rig.freeze()
        emit(["kind": "state", "v": 1])
        emit(["kind": "action"])
        #expect(rig.wakes == 1)
        #expect(rig.events == [["kind": "state", "v": 1], ["kind": "action"]])
    }

    @Test func theInputStreamThawsThePageForEachEvent() async throws {
        let provider = StreamProvider(.input)
        let rig = Rig(provider)
        _ = try #require(await rig.subscribe("test.input"))
        rig.freeze()
        provider.emit?(["key": "a"])
        #expect(rig.wakes == 1)
        #expect(rig.events == [["key": "a"]])
    }

    /// A stream of changed members (a page's look: `{themeCSS}`, then `{settings}`): the held event
    /// gathers the newest of each member, the state the page reaches by applying them one by one.
    @Test func aMembersStreamGathersTheNewestOfEachMemberForTheThaw() async throws {
        let provider = StreamProvider(.members)
        let rig = Rig(provider)
        _ = try #require(await rig.subscribe("test.look"))
        let emit = try #require(provider.emit)
        rig.freeze()
        emit(["themeCSS": "a"])
        emit(["settings": ["size": 1]])
        emit(["themeCSS": "b"])
        #expect(rig.wakes == 0, "a look push thawed the page")
        #expect(rig.router.frozen.count == 1)

        rig.router.thaw()
        #expect(rig.events == [["themeCSS": "b", "settings": ["size": 1]]])
    }

    /// A folded stream (a change notice that names what changed) holds one event that names
    /// everything changed while the page was frozen.
    @Test func aFoldedStreamHoldsOneEventMadeByItsFold() async throws {
        let provider = StreamProvider(.folded { held, later in
            .number((held?.doubleValue ?? 0) + (later.doubleValue ?? 0))
        })
        let rig = Rig(provider)
        _ = try #require(await rig.subscribe("test.count"))
        let emit = try #require(provider.emit)
        rig.freeze()
        for _ in 0..<100 { emit(1) }
        #expect(rig.wakes == 0)
        rig.router.thaw()
        #expect(rig.events == [100])
    }

    /// The built-in streams: the link state is state, a command is the person's and goes now.
    @Test func theLinkStateWaitsAndACommandThawsThePage() async throws {
        let rig = Rig(StreamProvider(.newest))
        _ = await rig.router.handle(["t": "sub", "id": 1, "stream": .string(PageNativeOp.pageConnection)])
        _ = await rig.router.handle(["t": "sub", "id": 2, "stream": .string(PageNativeOp.pageCommand)])
        // Let the connection stream's first event (after its reply) go.
        await Task.yield()
        let before = rig.events.count
        rig.freeze()
        rig.router.publishConnection(false)
        rig.router.publishConnection(true)
        rig.router.publishConnection(false)
        #expect(rig.events.count == before)
        #expect(rig.wakes == 0)

        rig.router.thaw()
        #expect(rig.events.count == before + 1)
        #expect(rig.events.last == ["connected": false])

        rig.freeze()
        #expect(rig.router.publishCommand(PageNativeOp.focusContent))
        #expect(rig.wakes == 1)
        #expect(rig.events.last?["command"]?.stringValue == PageNativeOp.focusContent)
    }

    /// A call of the host into the page needs the page to run: it thaws first.
    @Test func aHostCallThawsThePageFirst() async throws {
        let rig = Rig(StreamProvider(.newest))
        rig.freeze()
        // task-owner: the call waits for the page's reply, which the test never sends
        let call = Task { @MainActor in try await rig.router.callPage("cmux.page.command", params: .object([:])) }
        await Task.yield()
        #expect(rig.wakes == 1)
        #expect(rig.sent.last?["t"]?.stringValue == "call")
        #expect(rig.router.awaitsPageReplies)
        rig.router.close()
        _ = try? await call.value
        #expect(!rig.router.awaitsPageReplies)
    }

    /// The page says when its start is done (pageClient.ts `BOOTED`); a close forgets what was held.
    @Test func bootedReachesTheOwnerAndACloseDropsWhatWasHeld() async throws {
        let provider = StreamProvider(.newest)
        let rig = Rig(provider)
        var booted = 0
        rig.router.onBooted = { booted += 1 }
        #expect(await rig.router.handle(["t": "booted"]) == .null)
        #expect(booted == 1)

        _ = try #require(await rig.subscribe("test.state"))
        rig.freeze()
        provider.emit?(["n": 1])
        #expect(rig.router.frozen.count == 1)
        rig.router.reset()
        #expect(rig.router.frozen.count == 0)
        #expect(!rig.router.frozen.isFrozen)
    }
}
