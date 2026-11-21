import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// The Feed tab for a demonstration account: the agent feed normally fills
/// only over RPC from connected Macs, so without seeded content an App
/// Review account (no real Mac) saw "Feed Unavailable". Demonstration
/// content seeds believable agent-feed rows for the Demo Mac, and every row
/// interaction (open, triage, reply, full text) resolves locally without a
/// client. Unflagged accounts keep the old behavior.
@MainActor
@Suite struct MobileShellDemoAgentFeedTests {
    private typealias IdentityProvider = MobileShellDemoContentTests.DemoFlagIdentityProvider

    private func makeStore(
        demonstrationContentEnabled: Bool
    ) -> (CMUXMobileShellStore, IdentityProvider) {
        let identity = IdentityProvider(
            userID: "demo-feed-tests-user",
            demonstrationContentEnabled: demonstrationContentEnabled
        )
        let store = CMUXMobileShellStore(
            pairedMacStore: DemoContentPairedMacStore(
                inner: MobileShellDemoContentTests.RecordingPairedMacStore(),
                isEnabled: { await identity.demonstrationContentEnabled }
            ),
            identityProvider: identity,
            deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
            pairingHintDefaults: UserDefaults(
                suiteName: "demo-agent-feed-tests-\(UUID().uuidString)"
            )!
        )
        return (store, identity)
    }

    private func demoItems(_ store: CMUXMobileShellStore) -> [MobileAgentFeedItem] {
        store.agentFeedItems.filter {
            $0.macDeviceID == MobileDemoContentCatalog.macDeviceID
        }
    }

    @Test func demoAccountFeedIsReadyWithSampleAgentItems() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()

        #expect(store.agentFeedStatus == .ready)
        await store.refreshAgentFeed()
        #expect(store.agentFeedStatus == .ready)

        let items = demoItems(store)
        #expect(items.count == store.agentFeedItems.count)
        #expect(items.count >= 3)
        #expect(items.contains { $0.needsInput })
        #expect(items.contains { $0.kind == .stop && $0.supportsTerminalReply })
        #expect(items.contains { $0.kind == .assistantMessage })
        #expect(items.allSatisfy { $0.connectionStatus == .connected })
        #expect(items.allSatisfy { MobileDemoContentCatalog.ownsIdentifier($0.itemID) })
        #expect(store.agentFeedNeedsInputCount > 0)
        // Every row points at one of the demo workspaces.
        let workspaceTitles = Set(store.workspaces.map(\.name))
        #expect(items.allSatisfy { item in
            item.workspaceTitle.map(workspaceTitles.contains) == true
        })
    }

    @Test func demoPermissionAndQuestionRepliesResolveLocally() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()

        let permission = try #require(demoItems(store).first {
            $0.kind == .permissionRequest && $0.needsInput
        })
        let delivered = await store.submitAgentFeedPermissionReply(permission, mode: "once")
        #expect(delivered)
        let resolvedPermission = try #require(store.agentFeedItems.first { $0.id == permission.id })
        #expect(resolvedPermission.status == .resolved(
            MobileAgentFeedDecision(kind: "permission", mode: "once")
        ))
        #expect(!resolvedPermission.needsInput)

        let question = try #require(demoItems(store).first {
            $0.kind == .question && $0.needsInput
        })
        let optionID = try #require(question.questions.first?.options.first?.id)
        let answered = await store.submitAgentFeedQuestionReply(question, selections: [optionID])
        #expect(answered)
        let resolvedQuestion = try #require(store.agentFeedItems.first { $0.id == question.id })
        #expect(!resolvedQuestion.status.isPending)
        #expect(store.agentFeedPendingReplyRequestIDs.isEmpty)
        #expect(store.agentFeedStatus == .ready)
    }

    @Test func demoTerminalReplyAppearsAsTheUsersReply() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()

        let finished = try #require(demoItems(store).first {
            $0.kind == .stop && $0.supportsTerminalReply
        })
        let sent = await store.submitAgentFeedTerminalReply(finished, text: "  Ship it  ")
        #expect(sent)
        #expect(store.agentFeedFailedTerminalReplies[finished.id] == nil)
        #expect(store.agentFeedPendingTerminalReplyItemIDs.isEmpty)
        #expect(store.agentFeedItems.first { $0.id == finished.id }?.userReply == "Ship it")
    }

    @Test func demoRowsOpenTheirWorkspaceAndTerminalWithoutAMac() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()

        let item = try #require(demoItems(store).first {
            $0.remoteWorkspaceID != nil && $0.remoteSurfaceID != nil
        })
        let opened = await store.openAgentFeedDestination(item, openTab: true)
        #expect(opened)
        let selected = try #require(store.workspaces.first { $0.id == store.selectedWorkspaceID })
        #expect(selected.macDeviceID == MobileDemoContentCatalog.macDeviceID)
        #expect(selected.rpcWorkspaceID.rawValue == item.remoteWorkspaceID)
        #expect(store.selectedTerminalID?.rawValue == item.remoteSurfaceID)
        #expect(store.deeplinkWorkspaceNavigationRequest?.workspaceID == selected.id)
    }

    @Test func demoRowsTriageAndLoadFullTextLocally() async throws {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()

        let pending = try #require(demoItems(store).first { $0.needsInput })
        let countBefore = store.agentFeedNeedsInputCount
        store.setAgentFeedItemNeedsInput(pending, false)
        #expect(store.agentFeedItems.first { $0.id == pending.id }?.effectiveNeedsInput == false)
        #expect(store.agentFeedNeedsInputCount == countBefore - 1)
        store.setAgentFeedItemNeedsInput(pending, true)
        #expect(store.agentFeedItems.first { $0.id == pending.id }?.effectiveNeedsInput == true)

        let message = try #require(demoItems(store).first { $0.kind == .assistantMessage })
        let text = try await store.loadAgentFeedFullText(message)
        #expect(!text.isEmpty)
    }

    @Test func deactivationRemovesTheDemoAgentFeed() async throws {
        let (store, identity) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        let finished = try #require(demoItems(store).first { $0.supportsTerminalReply })
        _ = await store.submitAgentFeedTerminalReply(finished, text: "Thanks")
        #expect(!store.agentFeedItems.isEmpty)

        // The server flag is withdrawn; the next paired-Mac load deactivates.
        identity.demonstrationContentEnabled = false
        await store.loadPairedMacs()

        #expect(store.demoContentSession == nil)
        #expect(store.agentFeedItems.isEmpty)
        #expect(store.agentFeedSnapshotsByMac.isEmpty)
        #expect(store.agentFeedLocalRepliesByItemID.isEmpty)
        #expect(store.agentFeedStatus != .ready)
        await store.refreshAgentFeed()
        #expect(store.agentFeedStatus == .unavailable)
    }

    @Test func signOutRemovesTheDemoAgentFeed() async {
        let (store, _) = makeStore(demonstrationContentEnabled: true)
        store.signIn()
        #expect(!store.agentFeedItems.isEmpty)

        store.signOut()

        #expect(store.agentFeedItems.isEmpty)
        #expect(store.agentFeedStatus != .ready)
    }

    @Test func unflaggedAccountFeedStaysUnavailable() async {
        let (store, _) = makeStore(demonstrationContentEnabled: false)
        store.signIn()
        await store.refreshAgentFeed()

        #expect(store.agentFeedItems.isEmpty)
        #expect(store.agentFeedStatus == .unavailable)
    }
}
