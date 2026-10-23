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

        // Keep the second subscriber's handoff pending while the live subscriber receives the
        // same publication. Reset reports the live copy first; cancellation then requeues the
        // pending suffix, which must coalesce by publication identity.
        provider.replay = { Array(repeating: Self.command("prior"), count: 129) }
        let pending = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                   context: Self.context) { _ in }
        let mixed = AgentPageEvent(kind: "command", value: .string("mixed"), deliveryID: 77)
        #expect(provider.publish(mixed))
        provider.eventDeliveryDropped(stream: AgentPageProvider.hostEvents, data: mixed.data, publicationID: 77)
        live.cancel()
        pending.cancel()

        provider.replay = { [] }
        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null,
                                                context: Self.context) { event in nextPage.append(event) }
        defer { next.cancel() }
        await nextPage.waitFor(1)
        #expect(Self.names(nextPage.events) == ["mixed"])
    }
}
