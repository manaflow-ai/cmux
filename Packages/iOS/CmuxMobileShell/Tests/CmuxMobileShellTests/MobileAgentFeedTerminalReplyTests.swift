import CmuxMobileRPC
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Agent feed terminal replies")
struct MobileAgentFeedTerminalReplyTests {
    @Test("Event navigation uses the row target and rejects deleted tabs")
    func eventNavigation() async throws {
        let store = try await makeRoutingConnectedStore(router: RoutingHostRouter())
        store.replaceForegroundWorkspaceState([MobileWorkspacePreview(
            id: .init(rawValue: "agent-workspace"), macDeviceID: "test-mac",
            name: "Event workspace", terminals: [MobileTerminalPreview(id: .init(rawValue: "agent-surface"), name: "Agent")]
        )])
        let row = try item(in: store)
        #expect(await store.openAgentFeedDestination(row, openTab: true))
        #expect(store.deeplinkWorkspaceNavigationRequest?.workspaceID == store.workspaces.first?.id)
        // Feed rows push inside the Feed tab, so Back returns to the Feed.
        #expect(store.deeplinkWorkspaceNavigationRequest?.origin == .agentFeed)
        _ = store.consumeDeeplinkWorkspaceNavigationRequest()
        store.replaceForegroundWorkspaceState([MobileWorkspacePreview(
            id: .init(rawValue: "agent-workspace"), macDeviceID: "test-mac",
            name: "Event workspace", terminals: []
        )])
        #expect(!(await store.openAgentFeedDestination(row, openTab: true)))
        #expect(store.deeplinkWorkspaceNavigationRequest == nil)
        #expect(await store.openAgentFeedDestination(row, openTab: false))
    }

    private func item(
        in store: MobileShellComposite,
        source: String = "codex",
        owner: String = "test-mac",
        instanceTag: String? = nil
    ) throws -> MobileAgentFeedItem {
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": 1,
            "items": [[
                "id": "stop-1",
                "workstream_id": "\(source)-session-1",
                "source": source,
                "kind": "stop",
                "status": "telemetry",
                "created_at": "2026-09-14T12:00:00Z",
                "updated_at": "2026-09-14T12:00:00Z",
                "reason": "Done",
                "workspace_id": "agent-workspace",
                "surface_id": "agent-surface",
            ]],
        ])
        #expect(store.applyAgentFeedSnapshot(
            try MobileAgentFeedListResponse.decode(data),
            macDeviceID: MobilePairedMac.pairingID(macDeviceID: owner, instanceTag: instanceTag),
            displayName: "Agent Mac"
        ))
        return try #require(store.agentFeedItems.first)
    }

    @Test("Every provider routes multiline replies to the row's terminal", arguments:
        ["claude", "codex", "opencode", "pi", "cursor", "grok", "gemini"],
        ["Continue", "First line\nSecond line 🧪"]
    )
    func providerRouting(source: String, text: String) async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store, source: source)
        #expect(row.supportsTerminalReply)
        #expect(await store.submitAgentFeedTerminalReply(row, text: text))
        let paste = try #require(await router.pastes.first)
        #expect(paste.workspaceID == "agent-workspace")
        #expect(paste.surfaceID == "agent-surface")
        #expect(paste.text == text)
        #expect(paste.submitKey == "return")
        #expect(paste.feedEventID == row.itemID)
        #expect(store.agentFeedItems.first?.userReply == text)
        #expect(store.agentFeedPendingTerminalReplyItemIDs.isEmpty)
    }

    @Test("Replies use the owning secondary Mac instead of the selected Mac")
    func secondaryRouting() async throws {
        let foreground = RoutingHostRouter()
        let secondary = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: foreground,
            hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        try installSecondaryClient(
            on: store, macDeviceID: "other-mac", router: secondary,
            supportedHostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store, source: "opencode", owner: "other-mac")
        #expect(await store.submitAgentFeedTerminalReply(row, text: "Continue"))
        #expect(await foreground.pastes.isEmpty)
        #expect(await secondary.pastes.count == 1)
    }

    @Test("A failed submit key never creates a Replied marker")
    func failedSubmission() async throws {
        let router = RoutingHostRouter()
        await router.setFeedPasteSubmitted(false)
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store)
        #expect(await store.submitAgentFeedTerminalReply(row, text: "Continue") == false)
        #expect(store.agentFeedItems.first?.userReply == nil)
        #expect(store.agentFeedPendingTerminalReplyItemIDs.isEmpty)
        #expect(await router.pastes.count == 1)
        // The text reached the terminal, so the row must not offer a silent
        // resend; it keeps the text and reports that delivery is unconfirmed.
        #expect(store.agentFeedFailedTerminalReplies[row.id]
            == MobileAgentFeedFailedReply(text: "Continue", delivery: .unconfirmed))
    }

    @Test("A stale row cannot submit a second reply after success")
    func duplicateSubmission() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store)
        #expect(await store.submitAgentFeedTerminalReply(row, text: "Continue"))
        #expect(await store.submitAgentFeedTerminalReply(row, text: "Continue") == false)
        #expect(await router.pastes.count == 1)
    }

    @Test("Full text reading joins all pages from the owning Mac")
    func readFullText() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router, hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store)
        let first = String(repeating: "paragraph\n", count: 1_200)
        await router.setFeedTextPages([(first, 1, first.utf8.count), ("FINAL 👋", 1, nil)])
        #expect(try await store.loadAgentFeedFullText(row) == first + "FINAL 👋")
        let requests = await router.feedTextRequests
        #expect(requests.count == 2)
        #expect(requests.first?.itemID == row.itemID)
        #expect(requests.last?.offset == first.utf8.count)
        #expect(requests.last?.version == 1)
    }

    @Test("Changed content and nonadvancing pages fail instead of displaying partial text")
    func invalidFullTextPage() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router, hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store)
        await router.setFeedTextPages([("start", 1, 5), ("different", 2, nil)])
        await #expect(throws: URLError.self) { try await store.loadAgentFeedFullText(row) }
        await router.setFeedTextPages([("start", 1, 0)])
        await #expect(throws: URLError.self) { try await store.loadAgentFeedFullText(row) }
    }

    @Test("An offline reading target cannot fall back to the selected Mac")
    func offlineFullText() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router, hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store, instanceTag: "offline")
        await #expect(throws: URLError.self) { try await store.loadAgentFeedFullText(row) }
        #expect(await router.feedTextRequests.isEmpty)
    }

    @Test("An offline tagged owner cannot fall back to another instance")
    func offlineTaggedOwner() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(
            router: router,
            hostCapabilities: [MobileShellComposite.agentFeedCapability]
        )
        let row = try item(in: store, instanceTag: "offline")
        #expect(await store.submitAgentFeedTerminalReply(row, text: "Continue") == false)
        #expect(await router.pastes.isEmpty)
        #expect(store.agentFeedItems.first?.userReply == nil)
        #expect(store.agentFeedFailedTerminalReplies[row.id]
            == MobileAgentFeedFailedReply(text: "Continue", delivery: .notSent))
    }
}
