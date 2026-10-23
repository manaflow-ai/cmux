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
}
