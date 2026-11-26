import Foundation
import CmuxMobilePairedMac
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellForegroundNotificationReconcileTests {
    @Test(arguments: [false, true])
    func shortForegroundReturnClearsReadNotificationsWithoutRestartingConnection(hasStoredPairing: Bool) async throws {
        let router = RoutingHostRouter()
        let clearer = RecordingDeliveredNotificationClearer()
        clearer.deliveredIDs = ["read-1", "unread", "read-2", "unknown"]
        let store = try await connectedStore(router: router, clearer: clearer, hasStoredPairing: hasStoredPairing)
        defer { store.suspendForegroundRefresh() }
        let originalClient = store.remoteClient

        // No live dismissal arrives while backgrounded. The connection survives,
        // so terminal resubscription must not be needed to repair notifications.
        store.suspendForegroundRefresh()
        #expect(!store.shouldResyncTerminalOutputOnForeground())
        await router.setNotificationReconcile(handledIDs: ["read-1", "read-2"])
        store.resumeForegroundRefresh()
        #expect(try await pollUntil { await router.notificationReconciles.count == 2 })
        await store.notificationReconcileTask?.value

        #expect(clearer.clearedIDs == [["read-1", "read-2"]])
        #expect(clearer.clearedOwners.last?.macDeviceID == "test-mac")
        #expect(await router.notificationReconciles.count == 2)
        #expect(clearer.badgeCounts == [1, 1])
        #expect(store.remoteClient === originalClient)
    }

    @Test(arguments: [false, true])
    func unavailableReadStateKeepsDeliveredNotificationsAndBadge(hasStoredPairing: Bool) async throws {
        let router = RoutingHostRouter()
        let clearer = RecordingDeliveredNotificationClearer()
        clearer.deliveredIDs = ["read-1", "unread"]
        let store = try await connectedStore(router: router, clearer: clearer, hasStoredPairing: hasStoredPairing)
        defer { store.suspendForegroundRefresh() }

        store.suspendForegroundRefresh()
        await router.setNotificationReconcile(handledIDs: ["read-1"], rejects: true)
        store.resumeForegroundRefresh()
        #expect(try await pollUntil { await router.notificationReconciles.count == 2 })
        await store.notificationReconcileTask?.value

        #expect(await router.notificationReconciles.count == 2)
        #expect(clearer.clearedIDs.isEmpty)
        #expect(clearer.badgeCounts == [1])
        #expect(store.connectionState == .connected)
    }

    @Test func duplicateActiveSignalsCoalesceAndEachBackgroundReturnReconciles() async throws {
        let router = RoutingHostRouter()
        let clearer = RecordingDeliveredNotificationClearer()
        let store = try await connectedStore(router: router, clearer: clearer)
        defer { store.suspendForegroundRefresh() }

        for expectedCount in 2...3 {
            store.suspendForegroundRefresh()
            store.resumeForegroundRefresh()
            store.resumeForegroundRefresh()
            #expect(try await pollUntil { await router.notificationReconciles.count == expectedCount })
            await store.notificationReconcileTask?.value
            #expect(await router.notificationReconciles.count == expectedCount)
        }
    }

    private func connectedStore(
        router: RoutingHostRouter,
        clearer: RecordingDeliveredNotificationClearer,
        hasStoredPairing: Bool = false
    ) async throws -> MobileShellComposite {
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: ["events.v1", "terminal.bytes.v1"],
            pairedMacStore: hasStoredPairing
                ? DelayedTeamPairedMacStore(recordsByTeam: [:], blockedTeams: []) : nil,
            deliveredNotificationClearer: clearer
        )
        store.resumeForegroundRefresh()
        #expect(try await pollUntil { clearer.badgeCounts == [1] })
        #expect(store.terminalEventListenerTask != nil)
        return store
    }
}
