import CmuxMobileShellModel
import Foundation
import Testing

@Suite struct MobileAgentFeedItemTests {
    private func makeItem(
        kind: MobileAgentFeedItemKind,
        status: MobileAgentFeedItemStatus,
        requestID: String? = "req-1",
        workspaceID: String? = "ws-1",
        surfaceID: String? = "sf-1"
    ) -> MobileAgentFeedItem {
        MobileAgentFeedItem(
            macDeviceID: "mac-a",
            macDisplayName: "Desk Mac",
            itemID: "item-1",
            workstreamID: "claude-s1",
            source: "claude",
            kind: kind,
            status: status,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100),
            requestID: requestID,
            remoteWorkspaceID: workspaceID,
            remoteSurfaceID: surfaceID,
            connectionStatus: .connected
        )
    }

    @Test("Only pending actionable rows with a request id need input")
    func needsInput() {
        #expect(makeItem(kind: .permissionRequest, status: .pending).needsInput)
        #expect(makeItem(kind: .question, status: .pending).needsInput)
        #expect(makeItem(kind: .exitPlan, status: .pending).needsInput)
        #expect(!makeItem(kind: .permissionRequest, status: .pending, requestID: nil).needsInput)
        #expect(!makeItem(
            kind: .permissionRequest,
            status: .resolved(MobileAgentFeedDecision(kind: "permission", mode: "once"))
        ).needsInput)
        #expect(!makeItem(kind: .permissionRequest, status: .expired).needsInput)
        #expect(!makeItem(kind: .stop, status: .telemetry).needsInput)
        #expect(!makeItem(kind: .toolUse, status: .telemetry).needsInput)
    }

    @Test("Terminal replies require a stop row with a resolved target")
    func terminalReplySupport() {
        #expect(makeItem(kind: .stop, status: .telemetry).supportsTerminalReply)
        #expect(!makeItem(kind: .stop, status: .telemetry, workspaceID: nil).supportsTerminalReply)
        #expect(!makeItem(kind: .stop, status: .telemetry, surfaceID: nil).supportsTerminalReply)
        #expect(!makeItem(kind: .assistantMessage, status: .telemetry).supportsTerminalReply)
    }

    @Test("Unknown wire kinds map to unsupported and stay inert")
    func unknownKind() {
        #expect(MobileAgentFeedItemKind(rawValue: "hologram") == nil)
        let item = makeItem(kind: .unsupported, status: .pending)
        #expect(!item.needsInput)
        #expect(!item.kind.isActionable)
    }

    @Test("Updating preserves identity while replacing lifecycle state")
    func updating() {
        let item = makeItem(kind: .permissionRequest, status: .pending)
        let decision = MobileAgentFeedDecision(kind: "permission", mode: "deny")
        let resolved = item.updating(
            status: .resolved(decision),
            updatedAt: Date(timeIntervalSince1970: 200),
            connectionStatus: .reconnecting
        )
        #expect(resolved.id == item.id)
        #expect(resolved.status == .resolved(decision))
        #expect(resolved.updatedAt == Date(timeIntervalSince1970: 200))
        #expect(resolved.connectionStatus == .reconnecting)
        #expect(resolved.createdAt == item.createdAt)
    }
}
