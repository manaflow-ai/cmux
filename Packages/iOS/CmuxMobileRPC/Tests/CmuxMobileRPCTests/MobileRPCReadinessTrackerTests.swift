import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileRPCReadinessTrackerTests {
    private let usableSubscription = MobileRPCReadinessTracker.EventSubscription(
        streamID: "events",
        clientID: "phone-a",
        transport: "control_v1"
    )

    @Test
    func readinessRequiresWorkspaceAndLiveSubscriptionInEitherOrder() throws {
        var workspaceFirst = MobileRPCReadinessTracker()
        workspaceFirst.record(.workspaceList(count: 1))
        #expect(workspaceFirst.usableSession(whereEventSubscriptionIsLive: { _ in true }) == nil)
        workspaceFirst.record(.eventSubscription(usableSubscription))
        #expect(
            workspaceFirst.usableSession(whereEventSubscriptionIsLive: { _ in true })
                == .init(workspaceCount: 1, eventSubscription: usableSubscription)
        )

        var subscriptionFirst = MobileRPCReadinessTracker()
        subscriptionFirst.record(.eventSubscription(usableSubscription))
        subscriptionFirst.record(.workspaceList(count: 2))
        #expect(
            subscriptionFirst.usableSession(whereEventSubscriptionIsLive: { _ in true })
                == .init(workspaceCount: 2, eventSubscription: usableSubscription)
        )
    }

    @Test
    func emptyWorkspaceAndDeadOrRemovedSubscriptionFailClosed() {
        var tracker = MobileRPCReadinessTracker()
        tracker.record(.eventSubscription(usableSubscription))
        tracker.record(.workspaceList(count: 0))
        #expect(tracker.usableSession(whereEventSubscriptionIsLive: { _ in true }) == nil)

        tracker.record(.workspaceList(count: 1))
        #expect(tracker.usableSession(whereEventSubscriptionIsLive: { _ in false }) == nil)
        tracker.discardEventSubscription(streamID: usableSubscription.streamID)
        #expect(tracker.usableSession(whereEventSubscriptionIsLive: { _ in true }) == nil)
    }

    @Test
    func publicationIsOneShot() throws {
        var tracker = MobileRPCReadinessTracker()
        tracker.record(.workspaceList(count: 1))
        tracker.record(.eventSubscription(usableSubscription))
        _ = try #require(
            tracker.usableSession(whereEventSubscriptionIsLive: { _ in true })
        )

        tracker.markPublished()

        #expect(tracker.usableSession(whereEventSubscriptionIsLive: { _ in true }) == nil)
    }

    @Test
    func protocolContributionsRecognizeOnlyUsableResponses() {
        #expect(
            MobileRPCReadinessTracker.workspaceListContribution(
                method: "mobile.workspace.list",
                count: 1
            ) == .workspaceList(count: 1)
        )
        let completeTopics: Set<String> = [
            "workspace.updated",
            "mobile.sync.delta",
            "terminal.render_grid",
        ]
        #expect(
            MobileRPCReadinessTracker.eventSubscriptionContribution(
                method: "mobile.events.subscribe",
                topics: completeTopics,
                streamID: usableSubscription.streamID,
                clientID: usableSubscription.clientID,
                transport: usableSubscription.transport
            ) == .eventSubscription(usableSubscription)
        )
        #expect(
            MobileRPCReadinessTracker.eventSubscriptionContribution(
                method: "mobile.events.subscribe",
                topics: ["workspace.updated", "terminal.render_grid"],
                streamID: usableSubscription.streamID,
                clientID: usableSubscription.clientID,
                transport: usableSubscription.transport
            ) == nil
        )
    }
}
