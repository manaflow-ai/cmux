import CmuxMobileRPC
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Agent feed terminal replies")
struct MobileAgentFeedTerminalReplyTests {
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
    }
}
