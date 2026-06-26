import CmuxSidebarProviderKit
import Foundation
@testable import CmuxExtensionSidebarExamples
import Testing

@Suite("Attention queue sidebar")
struct AttentionQueueSidebarTests {
    @Test
    func localDisconnectedWorkspaceRemainsQuiet() throws {
        let local = workspace(
            title: "Local",
            customDescription: "Local project",
            remoteDisplayTarget: nil,
            remoteConnectionState: "disconnected"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [local]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        #expect(model.sections.first { $0.id == "attention" } == nil)
        let quiet = try #require(model.sections.first { $0.id == "quiet" })
        #expect(quiet.rows.map(\.workspaceId) == [local.id])
        #expect(quiet.rows.first?.subtitle == .plain("Local project"))
        #expect(quiet.rows.first?.subtitleRole == nil)
    }

    @Test
    func remoteDisconnectedWorkspaceNeedsAttention() throws {
        let remote = workspace(
            title: "Remote",
            customDescription: "Remote project",
            remoteDisplayTarget: "devbox",
            remoteConnectionState: "disconnected"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [remote]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        let attention = try #require(model.sections.first { $0.id == "attention" })
        #expect(attention.rows.map(\.workspaceId) == [remote.id])
        #expect(attention.rows.first?.subtitle == .plain("disconnected"))
        #expect(attention.rows.first?.subtitleRole == nil)
        #expect(model.sections.first { $0.id == "quiet" } == nil)
    }

    @Test
    func needsInputAgentStatusMarksLatestNotificationSubtitle() throws {
        let waiting = workspace(
            title: "Waiting",
            customDescription: "Agent workspace",
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            latestNotificationText: "入力が必要です",
            agentStatus: .needsInput,
            agentStatusText: "入力が必要です"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [waiting]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        let attention = try #require(model.sections.first { $0.id == "attention" })
        #expect(attention.rows.map(\.workspaceId) == [waiting.id])
        #expect(attention.rows.first?.subtitle == .plain("入力が必要です"))
        #expect(attention.rows.first?.subtitleRole == .agentStatus)
    }

    @Test
    func needsInputAgentStatusWithoutNotificationNeedsAttention() throws {
        let waiting = workspace(
            title: "Waiting",
            customDescription: "Agent workspace",
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            agentStatus: .needsInput,
            agentStatusText: "入力が必要です"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [waiting]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        let attention = try #require(model.sections.first { $0.id == "attention" })
        #expect(attention.rows.map(\.workspaceId) == [waiting.id])
        #expect(attention.rows.first?.subtitle == .plain("入力が必要です"))
        #expect(attention.rows.first?.subtitleRole == .agentStatus)
    }

    @Test
    func genericNotificationSubtitleKeepsProviderRole() throws {
        let notified = workspace(
            title: "Build",
            customDescription: "CI workspace",
            remoteDisplayTarget: nil,
            remoteConnectionState: nil,
            latestNotificationText: "Build failed in deploy step",
            agentStatus: .needsInput,
            agentStatusText: "Needs input"
        )
        let snapshot = CmuxSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: [notified]
        )

        let model = AttentionQueueSidebar().render(snapshot: snapshot)

        let attention = try #require(model.sections.first { $0.id == "attention" })
        #expect(attention.rows.map(\.workspaceId) == [notified.id])
        #expect(attention.rows.first?.subtitle == .plain("Build failed in deploy step"))
        #expect(attention.rows.first?.subtitleRole == nil)
    }

    private func workspace(
        title: String,
        customDescription: String?,
        remoteDisplayTarget: String?,
        remoteConnectionState: String?,
        latestNotificationText: String? = nil,
        agentStatus: CmuxSidebarProviderWorkspaceAgentStatus? = nil,
        agentStatusText: String? = nil
    ) -> CmuxSidebarProviderWorkspace {
        CmuxSidebarProviderWorkspace(
            id: UUID(),
            title: title,
            customDescription: customDescription,
            isPinned: false,
            rootPath: nil,
            projectRootPath: nil,
            branchSummary: nil,
            remoteDisplayTarget: remoteDisplayTarget,
            remoteConnectionState: remoteConnectionState,
            unreadCount: 0,
            latestNotificationText: latestNotificationText,
            agentStatus: agentStatus,
            agentStatusText: agentStatusText,
            listeningPorts: []
        )
    }
}
