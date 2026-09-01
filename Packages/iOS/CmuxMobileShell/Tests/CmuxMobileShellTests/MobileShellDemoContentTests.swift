import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// Demonstration content: server-flagged accounts see a local demo computer
/// with sample workspaces, notifications, and interactive canned terminals,
/// flowing through the SAME stores and derivations a live Mac's data uses.
/// Unflagged accounts must never see any of it, and sign-out must remove it.
@MainActor
@Suite struct MobileShellDemoContentTests {
    /// Identity double whose demonstration flag the tests control.
    final class DemoFlagIdentityProvider: MobileIdentityProviding {
        var currentUserID: String?
        var demonstrationContentEnabled: Bool

        init(userID: String?, demonstrationContentEnabled: Bool) {
            self.currentUserID = userID
            self.demonstrationContentEnabled = demonstrationContentEnabled
        }
    }

    /// Minimal inner store double: an empty, mutation-recording SQLite stand-in.
    final class RecordingPairedMacStore: MobilePairedMacStoring, @unchecked Sendable {
        var records: [MobilePairedMac] = []
        var upsertedDeviceIDs: [String] = []
        var removedDeviceIDs: [String] = []

        func upsert(
            macDeviceID: String,
            displayName: String?,
            routes: [CmxAttachRoute],
            instanceTag: String?,
            markActive: Bool,
            stackUserID: String?,
            teamID: String?,
            now: Date
        ) async throws {
            upsertedDeviceIDs.append(macDeviceID)
        }

        func loadAll(stackUserID: String?, teamID: String?) async throws -> [MobilePairedMac] {
            records
        }

        func activeMac(stackUserID: String?, teamID: String?) async throws -> MobilePairedMac? {
            nil
        }

        func setActive(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {}

        func clearActive(stackUserID: String?, teamID: String?) async throws {}

        func setCustomization(
            macDeviceID: String,
            customName: String?,
            customColor: String?,
            customIcon: String?,
            stackUserID: String?,
            teamID: String?,
            now: Date
        ) async throws {}

        func remove(macDeviceID: String, stackUserID: String?, teamID: String?) async throws {
            removedDeviceIDs.append(macDeviceID)
        }

        func removeAll() async throws {}

        func authorizeUserTailscaleRoutes(
            macDeviceID: String,
            instanceTag: String?,
            stackUserID: String?,
            teamID: String?,
            routes: [CmxAttachRoute]
        ) async throws {}
    }

    private func makeStore(
        demonstrationContentEnabled: Bool,
        inner: RecordingPairedMacStore = RecordingPairedMacStore()
    ) -> (CMUXMobileShellStore, RecordingPairedMacStore) {
        let identity = DemoFlagIdentityProvider(
            userID: "demo-tests-user",
            demonstrationContentEnabled: demonstrationContentEnabled
        )
        let store = CMUXMobileShellStore(
            pairedMacStore: DemoContentPairedMacStore(
                inner: inner,
                isEnabled: { await identity.demonstrationContentEnabled }
            ),
            identityProvider: identity,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: UserDefaults(
                suiteName: "demo-content-tests-\(UUID().uuidString)"
            )!
        )
        return (store, inner)
    }

    @Test func flaggedAccountSeesDemoComputerWorkspacesAndNotifications() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)

        store.signIn()

        let demoRows = store.workspaces.filter {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }
        #expect(!demoRows.isEmpty)
        #expect(demoRows.allSatisfy { $0.macConnectionStatus == .connected })
        // The list chrome must read connected off the demo entry even with no
        // real foreground connection, so the shell renders normally.
        #expect(store.workspaceListConnectionStatus == .connected)
        // The known-Mac hint keeps the root on the workspace shell instead of
        // the add-device flow.
        #expect(store.hasKnownPairedMac)
        // Sample notifications render through the ordinary aggregated feed.
        #expect(!store.notificationFeedItems.isEmpty)
        #expect(store.notificationFeedStatus == .ready)

        await store.loadPairedMacs()
        #expect(store.pairedMacs.contains {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
    }

    /// Live-repro regression (PR #11289 dogfood): on a launch that mounts
    /// already authenticated, the shell's auth sync runs against the CACHED
    /// identity card, which predates the server flag and decodes as
    /// not-flagged. The fresh flagged user arrives later through session
    /// revalidation WITHOUT another isAuthenticated edge, so no further
    /// `signIn()` sync re-evaluates activation. The paired-Mac decorator
    /// reads the flag lazily on every load, so the Demo Mac row appeared
    /// ("Not connected · 0 workspaces") while the workspace/notification
    /// seeds never landed. Any paired-Mac list load that can reveal the row
    /// must therefore also re-evaluate activation.
    @Test func flagArrivingAfterTheAuthSyncSeedsOnTheNextPairedMacLoad() async {
        let identity = DemoFlagIdentityProvider(
            userID: "demo-tests-user",
            demonstrationContentEnabled: false
        )
        let store = CMUXMobileShellStore(
            pairedMacStore: DemoContentPairedMacStore(
                inner: RecordingPairedMacStore(),
                isEnabled: { await identity.demonstrationContentEnabled }
            ),
            identityProvider: identity,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: UserDefaults(
                suiteName: "demo-content-tests-\(UUID().uuidString)"
            )!
        )

        // Auth sync fires while the published user is the cached, unflagged
        // card: nothing may seed.
        store.signIn()
        #expect(store.workspaces.isEmpty)
        #expect(store.notificationFeedItems.isEmpty)

        // Revalidation refreshes the published user with the server flag; no
        // isAuthenticated edge accompanies it.
        identity.demonstrationContentEnabled = true

        // The next paired-Mac load (reconnect bootstrap, Computers sheet,
        // foreground refresh) reveals the demo row — and must seed with it.
        await store.loadPairedMacs()
        #expect(store.pairedMacs.contains {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        let demoRows = store.workspaces.filter {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }
        #expect(demoRows.count == 3)
        #expect(demoRows.allSatisfy { $0.macConnectionStatus == .connected })
        #expect(store.workspaceListConnectionStatus == .connected)
        #expect(!store.notificationFeedItems.isEmpty)
        #expect(store.hasKnownPairedMac)
    }

    /// Sign-in kicks off stored-Mac reconnect and secondary-aggregation
    /// churn: full reconcile passes prune retained per-Mac state and re-run
    /// list loads. The demo seeds must survive every pass (the demo row is
    /// visible through the store decorator, so pruning must retain its
    /// aggregate state), and repeated loads must stay idempotent — exactly
    /// one demo row, three workspaces, no feed duplication.
    @Test func seedsSurviveReconnectAndAggregationChurn() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        #expect(!store.notificationFeedItems.isEmpty)
        let seededFeedCount = store.notificationFeedItems.count

        // A full secondary reconcile pass (what presence heartbeats and
        // reconnect edges run after sign-in), then further list loads.
        await store.refreshSecondaryMacWorkspaces()
        await store.loadPairedMacs()
        await store.loadPairedMacs()

        let demoRows = store.workspaces.filter {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }
        #expect(demoRows.count == 3)
        #expect(demoRows.allSatisfy { $0.macConnectionStatus == .connected })
        #expect(store.workspaceListConnectionStatus == .connected)
        #expect(store.notificationFeedItems.count == seededFeedCount)
        #expect(
            store.pairedMacs.filter {
                $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
            }.count == 1
        )
    }

    @Test func unflaggedAccountSeesNothing() async {
        let (store, _) = makeStore(demonstrationContentEnabled: false)

        store.signIn()
        await store.loadPairedMacs()

        #expect(store.workspaces.isEmpty)
        #expect(store.notificationFeedItems.isEmpty)
        #expect(store.pairedMacs.isEmpty)
        #expect(!store.hasKnownPairedMac)
    }

    @Test func realMacsListAlongsideTheDemoComputer() async throws {
        let inner = RecordingPairedMacStore()
        inner.records = [
            MobilePairedMac(
                macDeviceID: "real-mac-1",
                displayName: "Office Mac",
                routes: [
                    try CmxAttachRoute(
                        id: "ts",
                        kind: .tailscale,
                        endpoint: .hostPort(host: "office-mac.example.ts.net", port: 58_465)
                    ),
                ],
                createdAt: Date(),
                lastSeenAt: Date(),
                isActive: true,
                stackUserID: "demo-tests-user"
            ),
        ]
        let (store, _) = makeStore(demonstrationContentEnabled: true, inner: inner)

        store.signIn()
        await store.loadPairedMacs()

        #expect(store.pairedMacs.contains { $0.macDeviceID == "real-mac-1" })
        #expect(store.pairedMacs.contains {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        // The demo row augments the account's real Macs, it never replaces
        // or reorders them ahead of a fresher real pairing.
        #expect(store.pairedMacs.first?.macDeviceID == "real-mac-1")
    }

    @Test func signOutRemovesEveryDemonstrationSeed() {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        #expect(!store.workspaces.isEmpty)

        store.signOut()

        #expect(store.demoContentSession == nil)
        #expect(store.workspaces.isEmpty)
        #expect(store.notificationFeedItems.isEmpty)
        #expect(!store.hasKnownPairedMac)
    }

    @Test func openingADemoWorkspaceSelectsItAndClearsUnread() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let unreadRow = try #require(store.workspaces.first {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID && $0.hasUnread
        })

        await store.openWorkspace(unreadRow.id)

        #expect(store.selectedWorkspaceID == unreadRow.id)
        let reopened = store.workspaces.first { $0.id == unreadRow.id }
        #expect(reopened?.hasUnread == false)
    }

    @Test func demoTerminalReplaysCannedSessionOnMount() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let surfaceID = "cmux-demo-term-review-agent"

        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let replay = await iterator.next()

        let replayText = String(decoding: replay?.data ?? Data(), as: UTF8.self)
        #expect(replayText.contains("review PR #412"))
        #expect(replay?.requiresVerifiedReplay == false)
    }

    @Test func typedInputEchoesAndEnterRunsCannedCommand() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let surfaceID = "cmux-demo-term-review-agent"

        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let replay = await iterator.next()
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replay!.streamToken)

        await store.submitTerminalRawInput(Data("pwd".utf8), surfaceID: surfaceID)
        let echo = await iterator.next()
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: echo!.streamToken)
        #expect(String(decoding: echo?.data ?? Data(), as: UTF8.self) == "pwd")

        await store.submitTerminalRawInput(Data("\r".utf8), surfaceID: surfaceID)
        let response = await iterator.next()
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: response!.streamToken)
        let responseText = String(decoding: response?.data ?? Data(), as: UTF8.self)
        #expect(responseText.contains("/Users/demo/code/api-server"))
        // The next prompt follows the output, ready for more typing.
        #expect(responseText.contains("demo@demo-mac"))
    }

    @Test func demoInputPathsReportSendable() {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let row = store.workspaces.first {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }!

        #expect(store.canSendTerminalInput(to: row.id))
    }

    @Test func markingDemoNotificationsReadWorksWithoutAnyClient() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let unread = store.notificationFeedItems.filter { !$0.isRead }
        #expect(!unread.isEmpty)

        await store.markNotificationFeedItemRead(unread[0])
        #expect(
            store.notificationFeedItems.first {
                $0.notificationID == unread[0].notificationID
            }?.isRead == true
        )

        await store.markNotificationFeedItemsRead(scopedTo: nil)
        #expect(store.notificationFeedItems.allSatisfy { $0.isRead })
        #expect(store.notificationFeedUnreadCount == 0)
    }

    @Test func decoratorSwallowsMutationsAddressedToTheDemoRecord() async throws {
        let inner = RecordingPairedMacStore()
        let decorated = DemoContentPairedMacStore(
            inner: inner,
            isEnabled: { true }
        )

        try await decorated.remove(
            macDeviceID: MobileDemoContentCatalog.macDeviceID,
            stackUserID: "u",
            teamID: nil
        )
        try await decorated.upsert(
            macDeviceID: MobileDemoContentCatalog.macDeviceID,
            displayName: "x",
            routes: [],
            instanceTag: nil,
            markActive: true,
            stackUserID: "u",
            teamID: nil,
            now: Date()
        )
        try await decorated.remove(macDeviceID: "real-mac", stackUserID: "u", teamID: nil)

        #expect(inner.removedDeviceIDs == ["real-mac"])
        #expect(inner.upsertedDeviceIDs.isEmpty)
    }

    @Test func decoratorOverlaysOnlyWhileEnabled() async throws {
        final class Flag: @unchecked Sendable {
            var value = true
        }
        let inner = RecordingPairedMacStore()
        let enabled = Flag()
        let decorated = DemoContentPairedMacStore(
            inner: inner,
            isEnabled: { enabled.value }
        )

        let withDemo = try await decorated.loadAll(stackUserID: "u", teamID: "t")
        #expect(withDemo.count == 1)
        #expect(withDemo[0].macDeviceID == MobileDemoContentCatalog.macDeviceID)
        // The synthesized row carries the caller's scope so user/team-scoped
        // loads keep it visible, and it is never the active pairing.
        #expect(withDemo[0].stackUserID == "u")
        #expect(withDemo[0].teamID == "t")
        #expect(!withDemo[0].isActive)
        #expect(withDemo[0].routes.isEmpty)

        enabled.value = false
        let withoutDemo = try await decorated.loadAll(stackUserID: "u", teamID: "t")
        #expect(withoutDemo.isEmpty)
    }
}
