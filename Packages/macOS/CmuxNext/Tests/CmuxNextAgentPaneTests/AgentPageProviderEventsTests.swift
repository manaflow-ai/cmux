import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite(.serialized)
@MainActor
struct AgentPageProviderEventsTests {
    private static let context = PageCallContext(page: PageDescriptor.agent.id)

    private final class Received {
        var events: [JSONValue] = []
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func append(_ event: JSONValue) {
            events.append(event)
            if let waiter, events.count >= waiter.count {
                self.waiter = nil
                waiter.continuation.resume()
            }
        }

        func waitFor(_ count: Int) async {
            guard events.count < count else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiter = (count, continuation)
            }
        }
    }

    private final class CountWaiter {
        private let target: Int
        private var count = 0
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ target: Int) { self.target = target }

        func add() {
            count += 1
            if count >= target, let continuation {
                self.continuation = nil
                continuation.resume()
            }
        }

        func wait() async {
            guard count < target else { return }
            await withCheckedContinuation { continuation = $0 }
        }
    }

    private static func command(_ name: String) -> AgentPageEvent {
        .command(name)
    }

    private static func names(_ events: [JSONValue]) -> [String] {
        events.compactMap { event in
            guard case .string(let name)? = event["value"] else { return nil }
            return name
        }
    }

    @Test func eventsPublishedAcrossBridgeGapReplayInOrder() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { [Self.command("current-state")] }
        let firstPage = Received()
        provider.publish(Self.command("gap-1"))
        provider.publish(Self.command("gap-2"))

        let first = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            firstPage.append(event)
        }
        provider.publish(Self.command("after-subscribe"))
        await firstPage.waitFor(4)
        #expect(Self.names(firstPage.events) == ["current-state", "gap-1", "gap-2", "after-subscribe"])

        first.cancel()
        provider.publish(Self.command("second-gap-1"))
        provider.publish(Self.command("second-gap-2"))

        let secondPage = Received()
        let second = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            secondPage.append(event)
        }
        defer { second.cancel() }
        await secondPage.waitFor(3)
        #expect(Self.names(secondPage.events) == ["current-state", "second-gap-1", "second-gap-2"])
    }

    @Test func transportReconnectClearsOverflowForTheExistingSubscription() {
        let provider = AgentPageProvider { _ in nil }
        for index in 0...AgentPageProvider.maximumBufferedEvents {
            provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents,
                                          data: Self.command("dropped-\(index)").data,
                                          publicationID: UInt64(index + 1))
        }
        #expect(!provider.publish(Self.command("closed")))
        provider.transportDidOpen(1)
        #expect(provider.publish(Self.command("after-reconnect")))
    }

    @Test func routerResetDropUsesTheCapturedProviderAfterRouterCloses() async throws {
        let provider = AgentPageProvider { _ in nil }
        let router = PageRouter(descriptor: .agent, routes: [PageRoute(prefix: AgentPageOps.namespace, provider: provider)])
        var dropped: (@MainActor () -> Void)?
        let delivered = CountWaiter(1)
        router.sendWithDrop = { _, onDrop in
            dropped = onDrop
            delivered.add()
        }
        _ = await router.handle(["t": .string("sub"), "id": .number(1), "stream": .string(AgentPageProvider.hostEvents)])
        provider.publish(Self.command("router-reset"))
        // A new subscription's events go out in a later main-actor turn, after its subscribe reply
        // (AgentPageProvider.subscribe); wait for that delivery, not for the publish call.
        await delivered.wait()
        #expect(dropped != nil)
        router.close()
        dropped?()

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            nextPage.append(event)
        }
        defer { next.cancel() }
        await nextPage.waitFor(1)
        #expect(Self.names(nextPage.events) == ["router-reset"])
    }

    @Test func resetOfMultipleSubscribersRequeuesOnePublication() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { [Self.command("initial")] }
        let router = PageRouter(descriptor: .agent,
                                routes: [PageRoute(prefix: AgentPageOps.namespace, provider: provider)])
        var dropped: [@MainActor () -> Void] = []
        let replayed = CountWaiter(2)
        router.sendWithDrop = { _, onDrop in
            dropped.append(onDrop)
            replayed.add()
        }
        _ = await router.handle(["t": .string("sub"), "id": .number(1), "stream": .string(AgentPageProvider.hostEvents)])
        _ = await router.handle(["t": .string("sub"), "id": .number(2), "stream": .string(AgentPageProvider.hostEvents)])
        await replayed.wait()
        dropped.removeAll()

        #expect(provider.publish(Self.command("same")))
        #expect(dropped.count == 2)
        let firstPublicationDrops = dropped
        dropped.removeAll()
        #expect(provider.publish(Self.command("same")))
        #expect(dropped.count == 2)
        let secondPublicationDrops = dropped
        router.close()
        (firstPublicationDrops + secondPublicationDrops).forEach { $0() }

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                context: Self.context) { event in nextPage.append(event) }
        defer { next.cancel() }
        await nextPage.waitFor(3)
        #expect(Self.names(nextPage.events) == ["initial", "same", "same"])
    }

    @Test func mixedLiveAndPendingResetDropsRequeueOnePublication() async throws {
        let provider = AgentPageProvider { _ in nil }
        let livePage = Received()
        let live = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                context: Self.context) { event in livePage.append(event) }
        provider.publish(Self.command("live"))
        await livePage.waitFor(1)

        provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents,
                                      data: Self.command("old").data, publicationID: 1)
        provider.replay = { [] }
        let pending = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                   context: Self.context) { _ in }
        let newer = AgentPageEvent(kind: "command", value: .string("newer"), deliveryID: 2)
        #expect(provider.publish(newer))
        provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents, data: newer.data, publicationID: 2)
        live.cancel()
        pending.cancel()

        provider.replay = { [] }
        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                context: Self.context) { event in nextPage.append(event) }
        defer { next.cancel() }
        await nextPage.waitFor(2)
        #expect(Self.names(nextPage.events) == ["old", "newer"])
    }

    @Test func pendingCancelSkipsPublicationDeliveredToEarlierLiveSubscriber() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { [Self.command("live-sentinel")] }
        let livePage = Received()
        let live = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { livePage.append($0) }
        await livePage.waitFor(1)
        provider.replay = {
            _ = provider.publish(Self.command("delivered"))
            return [Self.command("snapshot")]
        }
        let pending = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { _ in }
        provider.transportDidOpen(1)
        pending.cancel()
        live.cancel()
        provider.replay = { [Self.command("next-sentinel")] }
        let page = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { page.append($0) }
        defer { next.cancel() }
        await page.waitFor(1)
        #expect(Self.names(page.events) == ["next-sentinel"])
    }

    @Test func pendingFanoutCancelAndFlushDoesNotLeaveBufferedCopy() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { Array(repeating: Self.command("hold"), count: 129) }
        let first = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { _ in }
        provider.replay = {
            #expect(provider.publish(Self.command("fanout")))
            return [Self.command("second")]
        }
        let secondPage = Received()
        let second = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { secondPage.append($0) }
        first.cancel()
        await secondPage.waitFor(2)
        second.cancel()
        provider.replay = { [Self.command("next")] }
        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { nextPage.append($0) }
        defer { next.cancel() }
        await nextPage.waitFor(1)
        #expect(Self.names(nextPage.events) == ["next"])
    }

    @Test func lateDropMergesBehindEarlierRecoveredPublication() async throws {
        let provider = AgentPageProvider { _ in nil }
        let live = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { _ in }
        #expect(provider.publish(AgentPageEvent(kind: "command", value: .string("old"), deliveryID: 1)))
        live.cancel()
        provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents,
                                      data: AgentPageEvent(kind: "command", value: .string("new"), deliveryID: 2).data,
                                      publicationID: 2)
        provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents,
                                      data: AgentPageEvent(kind: "command", value: .string("old"), deliveryID: 1).data,
                                      publicationID: 1)
        provider.replay = { [] }
        let page = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { page.append($0) }
        defer { next.cancel() }
        await page.waitFor(2)
        #expect(Self.names(page.events) == ["old", "new"])
    }
}
