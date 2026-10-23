import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Host pushes must survive the shared page host's subscription gap. A WebView reload cancels
/// the old subscription before the new document installs its bridge; transport events in between
/// still reach the replacement page in their original order.
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

    private final class SubscriptionHolder {
        var value: PageSubscription?
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
        // This event lands after the subscribe reply is built but before the replay task runs.
        // It must queue behind the two events received during the gap.
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

    @Test func liveEventsFanOutToMultipleSubscribersWithoutReordering() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { [Self.command("current-state")] }
        let firstPage = Received()
        let first = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            firstPage.append(event)
        }
        defer { first.cancel() }
        let secondPage = Received()
        let second = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            secondPage.append(event)
        }
        defer { second.cancel() }
        provider.publish(Self.command("live"))
        await firstPage.waitFor(2)
        await secondPage.waitFor(2)

        #expect(Self.names(firstPage.events) == ["current-state", "live"])
        #expect(Self.names(secondPage.events) == ["current-state", "live"])
    }

    @Test func cancelledReplayReturnsUndeliveredEventsToTheNextPage() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.publish(Self.command("gap"))

        let droppedPage = Received()
        let dropped = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            droppedPage.append(event)
        }
        dropped.cancel()
        #expect(droppedPage.events.isEmpty)

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            nextPage.append(event)
        }
        defer { next.cancel() }
        await nextPage.waitFor(1)
        #expect(Self.names(nextPage.events) == ["gap"])
    }

    @Test func selfCancellationRequeuesTheSuffixOnce() async throws {
        let provider = AgentPageProvider { _ in nil }
        for name in ["first", "second", "third"] { provider.publish(Self.command(name)) }

        let holder = SubscriptionHolder()
        let firstPage = Received()
        holder.value = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            firstPage.append(event)
            if firstPage.events.count == 1 { holder.value?.cancel() }
        }
        await firstPage.waitFor(1)
        #expect(Self.names(firstPage.events) == ["first"])

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            nextPage.append(event)
        }
        defer { next.cancel() }
        await nextPage.waitFor(2)
        #expect(Self.names(nextPage.events) == ["second", "third"])
    }

    @Test func fullBacklogUsesExplicitBackpressureWithoutEviction() {
        let provider = AgentPageProvider { _ in nil }
        for index in 0..<AgentPageProvider.maximumBufferedEvents {
            #expect(provider.publish(Self.command("buffered-\(index)")))
        }
        #expect(!provider.publish(Self.command("backpressure")))
    }

    @Test func droppedBacklogOverflowSignalsResyncInsteadOfEvicting() {
        let provider = AgentPageProvider { _ in nil }
        for index in 0...AgentPageProvider.maximumBufferedEvents {
            provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents,
                                          data: Self.command("dropped-\(index)").data)
        }
        #expect(!provider.publish(Self.command("backpressure")))
    }

    @Test func transportReconnectClearsOverflowForTheExistingSubscription() {
        let provider = AgentPageProvider { _ in nil }
        for index in 0...AgentPageProvider.maximumBufferedEvents {
            provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents,
                                          data: Self.command("dropped-\(index)").data)
        }
        #expect(!provider.publish(Self.command("closed")))
        provider.transportDidOpen(1)
        #expect(provider.publish(Self.command("after-reconnect")))
    }

    @Test func transportReconnectKeepsARecoverableBridgeGapQueue() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.publish(Self.command("kept"))
        provider.transportDidOpen(1)
        let page = Received()
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                         context: Self.context) { event in page.append(event) }
        defer { subscription.cancel() }
        await page.waitFor(1)
        #expect(Self.names(page.events) == ["kept"])
    }

    @Test func transportReconnectResetsAStalledPendingReplay() async throws {
        let provider = AgentPageProvider { _ in nil }
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                         context: Self.context) { _ in }
        for index in 0..<AgentPageProvider.maximumBufferedEvents {
            #expect(provider.publish(Self.command("pending-\(index)")))
        }
        #expect(!provider.publish(Self.command("overflow")))
        provider.transportDidOpen(1)
        #expect(provider.publish(Self.command("after-reconnect")))
        subscription.cancel()
    }

    @Test func aPageResetRequeuesAnEnvelopeDroppedByTheScriptPipeline() async throws {
        let provider = AgentPageProvider { _ in nil }
        let page = Received()
        let subscription = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            page.append(event)
        }
        // PageScriptPipeline.reset reports this exact data before PageRouter cancels the old sub.
        let dropped = Self.command("reset-dropped")
        provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents, data: dropped.data)
        subscription.cancel()

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            nextPage.append(event)
        }
        defer { next.cancel() }
        await nextPage.waitFor(1)
        #expect(Self.names(nextPage.events) == ["reset-dropped"])
    }

    @Test func routerResetDropUsesTheCapturedProviderAfterRouterCloses() async throws {
        let provider = AgentPageProvider { _ in nil }
        let router = PageRouter(descriptor: .agent, routes: [PageRoute(prefix: AgentPageOps.namespace, provider: provider)])
        var dropped: (@MainActor () -> Void)?
        router.sendWithDrop = { _, onDrop in dropped = onDrop }
        _ = await router.handle(["t": .string("sub"), "id": .number(1), "stream": .string(AgentPageProvider.hostEvents)])
        provider.publish(Self.command("router-reset"))
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

    @Test func resetDroppedPrefixStaysBeforeRequeuedPendingSuffix() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.publish(Self.command("pending-prefix"))
        let old = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { _ in }
        provider.publish(Self.command("pending-suffix"))
        provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents, data: Self.command("reset-prefix").data)
        old.cancel()

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            nextPage.append(event)
        }
        defer { next.cancel() }
        await nextPage.waitFor(3)
        #expect(Self.names(nextPage.events) == ["reset-prefix", "pending-prefix", "pending-suffix"])
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
        router.close()
        dropped.forEach { $0() }

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                context: Self.context) { event in nextPage.append(event) }
        defer { next.cancel() }
        await nextPage.waitFor(2)
        #expect(Self.names(nextPage.events) == ["initial", "same"])
    }
}
