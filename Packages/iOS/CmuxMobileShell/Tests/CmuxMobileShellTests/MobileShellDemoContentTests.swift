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

    /// Live-repro regression (PR #11289 dogfood round 2): with the real Mac
    /// wedged/unreachable, every failed stored-Mac dial funnels into
    /// `clearRemoteConnectionContext()`, which drops every non-foreground
    /// `workspacesByMac` entry — including the demonstration Mac's. Real
    /// secondaries are re-established by the next aggregation pass; the demo
    /// Mac has no subscription, so each ~85s reconnect cycle erased all demo
    /// workspaces/terminals ("Demo Mac · Not connected · 0 workspaces", five
    /// terminalClosed events per cycle). Demo state must be invariant to
    /// connection teardown of any real Mac.
    @Test func connectionTeardownChurnKeepsDemoSeedsIntact() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        #expect(store.workspaces.count == 3)
        let seededFeedCount = store.notificationFeedItems.count

        // The single choke point every failed dial, manual-pairing failure,
        // and recovery teardown funnels through.
        store.clearRemoteConnectionContext()

        let demoRows = store.workspaces.filter {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }
        #expect(demoRows.count == 3)
        #expect(demoRows.allSatisfy { $0.macConnectionStatus == .connected })
        #expect(
            store.macConnectionStatuses[MobileDemoContentCatalog.macDeviceID]
                == .connected
        )
        #expect(store.workspaceListConnectionStatus == .connected)
        #expect(store.notificationFeedItems.count == seededFeedCount)
    }

    /// The exact user-visible failure from the live repro: tapping a demo
    /// workspace row while the teardown storm runs landed back on an empty
    /// list because the wipe raced the open (`rowWorkspaceID` resolved nil
    /// after `switchToMac` returned). After teardown, opening a demo row
    /// must keep its selection and present the canned terminal.
    @Test func openingADemoWorkspaceAfterTeardownChurnPresentsTheTerminal() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        store.clearRemoteConnectionContext()

        let row = try #require(store.workspaces.first {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        await store.openWorkspace(row.id)
        #expect(store.selectedWorkspaceID == row.id)

        let surfaceID = try #require(row.terminals.first?.id.rawValue)
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let replay = await iterator.next()
        #expect(!(replay?.data.isEmpty ?? true))
    }

    /// The stored-Mac reconnect loop iterates every saved row as a dial
    /// candidate. The demonstration row must never be one: it has nothing to
    /// dial, and running it through the reconnect machinery (registry route
    /// refresh, failure cleanup) is exactly the class of lifecycle
    /// participation that degraded it live. The attempt must leave every
    /// demo seed and its connected status untouched.
    @Test func storedMacReconnectAttemptNeverDegradesTheDemoComputer() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        #expect(store.workspaces.count == 3)

        let connected = await store.reconnectActiveMacIfAvailable(
            stackUserID: "demo-tests-user"
        )

        #expect(!connected)
        let demoRows = store.workspaces.filter {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }
        #expect(demoRows.count == 3)
        #expect(
            store.macConnectionStatuses[MobileDemoContentCatalog.macDeviceID]
                == .connected
        )
        #expect(store.workspaceListConnectionStatus == .connected)
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

    /// Owner requirement: EVERY demo workspace opens onto the interactive
    /// simulated terminal — canned transcript plus a live prompt that answers
    /// typed commands — not just the first one. Exercises each workspace's
    /// every terminal through the production open/mount/input paths.
    @Test func everyDemoWorkspaceOpensAnInteractiveSimulatedTerminal() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let demoWorkspaces = store.workspaces.filter {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }
        #expect(demoWorkspaces.count == 3)

        for workspace in demoWorkspaces {
            await store.openWorkspace(workspace.id)
            #expect(store.selectedWorkspaceID == workspace.id)
            #expect(!workspace.terminals.isEmpty)
            for terminal in workspace.terminals {
                let surfaceID = terminal.id.rawValue
                var iterator = store.terminalOutputStream(surfaceID: surfaceID)
                    .makeAsyncIterator()
                let replay = try #require(await iterator.next())
                #expect(!replay.data.isEmpty)
                store.terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: replay.streamToken
                )

                await store.submitTerminalRawInput(Data("pwd\r".utf8), surfaceID: surfaceID)
                let response = try #require(await iterator.next())
                store.terminalOutputDidProcess(
                    surfaceID: surfaceID,
                    streamToken: response.streamToken
                )
                let responseText = String(decoding: response.data, as: UTF8.self)
                #expect(responseText.contains("/Users/demo/"))
                #expect(responseText.contains("demo@demo-mac"))
            }
        }
    }

    /// Live-repro regression (PR #11289 dogfood round 3, blank canvas +
    /// `sinceOutput=-1`): the REAL mount order is gated. GhosttySurface's
    /// first geometry callback must obtain a viewport preparation from
    /// `prepareTerminalViewport` BEFORE the output consumer attaches the
    /// stream (`waitForOutputStart`); only a non-nil preparation opens the
    /// gate. `prepareTerminalViewport` resolves the workspace through the
    /// foreground-scoped `workspaceID(forTerminalID:)`, which returned nil
    /// for demo surfaces (demo rows are stamped with the demo mac id and the
    /// demo Mac is never foreground) — so the gate never opened, the sink
    /// never registered, and not one replay byte ever reached the surface.
    /// This test drives that exact order: geometry preparation, viewport
    /// report answer, THEN sink attach, THEN replay.
    @Test func demoMountFollowsTheRealViewportGateOrder() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let row = try #require(store.workspaces.first {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        await store.openWorkspace(row.id)
        let surfaceID = try #require(row.terminals.first?.id.rawValue)

        // 1. First geometry callback: the preparation must exist or the
        //    output gate never opens.
        let preparation = try #require(store.prepareTerminalViewport(
            surfaceID: surfaceID,
            columns: 80,
            rows: 24
        ))

        // 2. The scheduled viewport report must answer with an effective
        //    grid (locally, no Mac): a nil answer puts the real view into a
        //    bounded retry loop and leaves the letterbox unsettled.
        let grid = await store.updatePreparedTerminalViewport(preparation)
        #expect(grid?.columns == 80)
        #expect(grid?.rows == 24)

        // 3. Only now does the consumer attach the sink; the cold replay
        //    must arrive AFTER this registration.
        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let replay = try #require(await iterator.next())
        let replayText = String(decoding: replay.data, as: UTF8.self)
        #expect(replayText.contains("review PR #412"))
    }

    /// Live-repro regression (round 3, "Couldn’t send. Check the connection
    /// and try again."): the composer band submits through
    /// `submitComposerInput`/`submitComposer` → `terminal.paste` on the
    /// foreground client, which is nil while only the demo Mac serves
    /// content — so the send failed its connection gate before reaching the
    /// demo input fence. Drives the composer's ACTUAL send entries.
    @Test func composerSendEntriesDeliverToTheDemoTerminal() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let row = try #require(store.workspaces.first {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        await store.openWorkspace(row.id)
        let terminalID = try #require(store.selectedTerminalID)
        #expect(store.demonstrationOwnsSurface(terminalID.rawValue))

        var iterator = store.terminalOutputStream(surfaceID: terminalID.rawValue)
            .makeAsyncIterator()
        let replay = try #require(await iterator.next())
        store.terminalOutputDidProcess(
            surfaceID: terminalID.rawValue,
            streamToken: replay.streamToken
        )

        // The text-only composer entry (Return key / send button).
        store.terminalInputText = "echo from-composer"
        let sent = await store.submitComposerInput()
        // require (not expect): a failed send means no echo ever arrives,
        // and awaiting the stream would hang the suite.
        try #require(sent)
        let echo = try #require(await iterator.next())
        store.terminalOutputDidProcess(
            surfaceID: terminalID.rawValue,
            streamToken: echo.streamToken
        )
        #expect(String(decoding: echo.data, as: UTF8.self).contains("from-composer"))

        // The full composer pipeline (the one whose failure shows the red
        // "Couldn't send" banner through the terminal send status).
        store.terminalInputText = "pwd"
        let submitted = await store.submitComposer()
        try #require(submitted)
        #expect(store.terminalSendStatus(forTerminalID: terminalID.rawValue) != .failed)
        let response = try #require(await iterator.next())
        store.terminalOutputDidProcess(
            surfaceID: terminalID.rawValue,
            streamToken: response.streamToken
        )
        #expect(String(decoding: response.data, as: UTF8.self)
            .contains("/Users/demo/code/api-server"))
    }

    /// Owner-phone regression (round 4): re-entering a demo workspace after
    /// hours of background/foreground churn found a blank canvas and the
    /// send-failure banner. Whatever tears the session down (every teardown
    /// funnels through deactivateDemonstrationContent), a mounted demo
    /// surface must SELF-HEAL at interaction time: ownership is derived from
    /// the stable `cmux-demo-` id namespace, and the first replay/viewport/
    /// input interaction recreates the session and reseeds. The invariant: a
    /// demo workspace opened any number of times, after any lifecycle,
    /// always paints and always routes input to the engine.
    @Test func demoSurfaceSelfHealsAfterSessionTeardownOnReentry() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let row = try #require(store.workspaces.first {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        await store.openWorkspace(row.id)
        let surfaceID = try #require(row.terminals.first?.id.rawValue)

        // Simulate the round-4 phone state: the demo session died underneath
        // a still-presented detail (rows gone, session nil).
        store.deactivateDemonstrationContent()
        #expect(store.demoContentSession == nil)

        // Re-entry mounts through the real order: geometry preparation must
        // succeed (self-healing the session), the viewport must answer, and
        // the sink attach must replay the canned session.
        let preparation = try #require(store.prepareTerminalViewport(
            surfaceID: surfaceID,
            columns: 80,
            rows: 24
        ))
        let grid = await store.updatePreparedTerminalViewport(preparation)
        #expect(grid?.columns == 80)

        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let replay = try #require(await iterator.next())
        #expect(String(decoding: replay.data, as: UTF8.self).contains("review PR #412"))

        // The heal restored the seeds too, so the list recovers.
        #expect(store.demoContentSession != nil)
        #expect(store.workspaces.contains {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
    }

    /// Owner directive (round 4): typing after focusing INTO the terminal on
    /// the phone must echo through the engine. The on-screen keyboard enters
    /// through `ghosttySurfaceView(_:didProduceInput:)` →
    /// `sendTerminalRawInput(_ data:surfaceID:)` — the synchronous send-status
    /// pipeline, NOT the awaiting funnel earlier tests drove — so this drives
    /// that exact entry.
    @Test func onScreenKeyboardPathEchoesThroughTheEngine() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let row = try #require(store.workspaces.first {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
        await store.openWorkspace(row.id)
        let surfaceID = try #require(row.terminals.first?.id.rawValue)

        var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
        let replay = try #require(await iterator.next())
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replay.streamToken)

        // The Ghostty key-input delegate entry (typing on the phone keyboard).
        store.sendTerminalRawInput(Data("ls".utf8), surfaceID: surfaceID)

        // The engine saw the keystrokes (require first: a mis-routed send
        // would leave the stream silent and an await would hang the suite).
        let session = try #require(store.demoContentSession)
        let engineLine = String(
            decoding: session.engine.replayBytes(surfaceID: surfaceID) ?? Data(),
            as: UTF8.self
        )
        try #require(engineLine.hasSuffix("ls"))

        let echo = try #require(await iterator.next())
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: echo.streamToken)
        #expect(String(decoding: echo.data, as: UTF8.self) == "ls")

        // Enter through the same entry runs the command.
        store.sendTerminalRawInput(Data("\r".utf8), surfaceID: surfaceID)
        let response = try #require(await iterator.next())
        store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: response.streamToken)
        let responseText = String(decoding: response.data, as: UTF8.self)
        #expect(responseText.contains("src"))
        #expect(responseText.contains("demo@demo-mac"))
        // And the send-status pipeline never flags a failure for demo input.
        #expect(store.terminalSendStatus(forTerminalID: surfaceID) != .failed)
    }

    /// Owner directive (round 4): the task composer must never operate
    /// against the demo Mac (a fake Mac cannot run real tasks). With only
    /// the demo computer, the composer entry hides entirely; with a real Mac
    /// alongside, the composer stays available but its target list excludes
    /// the demo computer.
    @Test func taskComposerNeverTargetsTheDemoComputer() async throws {
        let (demoOnlyStore, _) = makeStore(demonstrationContentEnabled: true)
        demoOnlyStore.signIn()
        await demoOnlyStore.loadPairedMacs()
        #expect(!demoOnlyStore.supportsTaskComposer)
        #expect(demoOnlyStore.taskComposerPairedMacs.isEmpty)

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
        let (mixedStore, _) = makeStore(demonstrationContentEnabled: true, inner: inner)
        mixedStore.signIn()
        await mixedStore.loadPairedMacs()
        // A real (even offline) Mac keeps the composer available…
        #expect(mixedStore.supportsTaskComposer)
        // …but the demo computer is never a target.
        #expect(mixedStore.taskComposerPairedMacs.contains { $0.macDeviceID == "real-mac-1" })
        #expect(!mixedStore.taskComposerPairedMacs.contains {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        })
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
