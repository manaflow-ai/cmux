import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileRPCReadinessTrackerTests {
    private let usableSubscription = MobileRPCReadinessTracker.EventSubscription(
        streamID: "events",
        clientID: "phone-a",
        launchID: "11111111-1111-1111-1111-111111111111",
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
    func currentSessionValidationRequiresTheExactLaunchTupleAndPositiveWorkspace() {
        var tracker = MobileRPCReadinessTracker()
        tracker.record(.workspaceList(count: 1))
        tracker.record(.eventSubscription(usableSubscription))

        #expect(tracker.hasCurrentUsableSession(
            matching: usableSubscription,
            whereEventSubscriptionIsLive: { $0 == usableSubscription }
        ))

        let staleLaunch = MobileRPCReadinessTracker.EventSubscription(
            streamID: usableSubscription.streamID,
            clientID: usableSubscription.clientID,
            launchID: "22222222-2222-2222-2222-222222222222",
            transport: usableSubscription.transport
        )
        #expect(!tracker.hasCurrentUsableSession(
            matching: staleLaunch,
            whereEventSubscriptionIsLive: { _ in true }
        ))

        tracker.record(.workspaceList(count: 0))
        #expect(!tracker.hasCurrentUsableSession(
            matching: usableSubscription,
            whereEventSubscriptionIsLive: { _ in true }
        ))
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
                launchID: usableSubscription.launchID,
                transport: usableSubscription.transport
            ) == .eventSubscription(usableSubscription)
        )
        #expect(
            MobileRPCReadinessTracker.eventSubscriptionContribution(
                method: "mobile.events.subscribe",
                topics: ["workspace.updated", "terminal.render_grid"],
                streamID: usableSubscription.streamID,
                clientID: usableSubscription.clientID,
                launchID: usableSubscription.launchID,
                transport: usableSubscription.transport
            ) == nil
        )

        let productionSubscription = MobileRPCReadinessTracker.EventSubscription(
            streamID: "production-events",
            clientID: "production-phone",
            launchID: nil,
            transport: "control_v1"
        )
        #expect(
            MobileRPCReadinessTracker.eventSubscriptionContribution(
                method: "mobile.events.subscribe",
                topics: completeTopics,
                streamID: productionSubscription.streamID,
                clientID: productionSubscription.clientID,
                launchID: nil,
                transport: productionSubscription.transport
            ) == .eventSubscription(productionSubscription)
        )
    }
}
