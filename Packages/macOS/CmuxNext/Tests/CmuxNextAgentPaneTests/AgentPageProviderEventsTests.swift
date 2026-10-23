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

    private static func settle() async {
        for _ in 0..<4 { await Task.yield() }
    }

    @Test func eventsPublishedAcrossBridgeGapReplayInOrder() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { [Self.command("current-state")] }
        let firstPage = Received()
        provider.publish(Self.command("gap-1"))
        provider.publish(Self.command("gap-2"))

        let first = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            firstPage.events.append(event)
        }
        // This event lands after the subscribe reply is built but before the replay task runs.
        // It must queue behind the two events received during the gap.
        provider.publish(Self.command("after-subscribe"))
        await Self.settle()
        #expect(Self.names(firstPage.events) == ["current-state", "gap-1", "gap-2", "after-subscribe"])

        first.cancel()
        provider.publish(Self.command("second-gap-1"))
        provider.publish(Self.command("second-gap-2"))

        let secondPage = Received()
        let second = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            secondPage.events.append(event)
        }
        defer { second.cancel() }
        await Self.settle()
        #expect(Self.names(secondPage.events) == ["current-state", "second-gap-1", "second-gap-2"])
    }

    @Test func liveEventsFanOutToMultipleSubscribersWithoutReordering() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.replay = { [Self.command("current-state")] }
        let firstPage = Received()
        let first = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            firstPage.events.append(event)
        }
        defer { first.cancel() }
        let secondPage = Received()
        let second = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            secondPage.events.append(event)
        }
        defer { second.cancel() }
        provider.publish(Self.command("live"))
        await Self.settle()

        #expect(Self.names(firstPage.events) == ["current-state", "live"])
        #expect(Self.names(secondPage.events) == ["current-state", "live"])
    }

    @Test func cancelledReplayReturnsUndeliveredEventsToTheNextPage() async throws {
        let provider = AgentPageProvider { _ in nil }
        provider.publish(Self.command("gap"))

        let droppedPage = Received()
        let dropped = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            droppedPage.events.append(event)
        }
        dropped.cancel()
        #expect(droppedPage.events.isEmpty)

        let nextPage = Received()
        let next = try await provider.subscribe(AgentPageProvider.hostEvents, filter: .null, context: Self.context) { event in
            nextPage.events.append(event)
        }
        defer { next.cancel() }
        await Self.settle()
        #expect(Self.names(nextPage.events) == ["gap"])
    }
}
