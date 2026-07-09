import Foundation
import Testing

@testable import CmuxWorkspaces

/// Pins the session-autosave fingerprint contract the autosave skip optimization
/// depends on: identical inputs hash identically, discriminating field changes
/// change the hash, and notification ordering does not (the service sorts by id).
///
/// `Hasher.finalize()` uses a per-process random seed, so these tests compare
/// fingerprints computed within one process exactly as the live autosave timer
/// compares previous vs current fingerprint within one app run; they never
/// assert a hardcoded constant.
@Suite
struct SessionFingerprintServiceTests {
    private let service = SessionFingerprintService()

    private func notification(
        id: UUID = UUID(),
        title: String = "t",
        subtitle: String = "s",
        body: String = "b",
        createdAt: Double = 1_000,
        isRead: Bool = false,
        paneFlash: Bool = true,
        panelId: UUID? = nil,
        clickAction: SessionFingerprintNotificationSnapshot.ClickAction? = nil
    ) -> SessionFingerprintNotificationSnapshot {
        SessionFingerprintNotificationSnapshot(
            id: id,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: createdAt,
            isRead: isRead,
            paneFlash: paneFlash,
            panelId: panelId,
            clickAction: clickAction
        )
    }

    private func panel(
        panelId: UUID = UUID(),
        directory: String = "",
        hasRemoteDirectoryReport: Bool = false,
        requiresRemoteDirectoryTrust: Bool = false,
        textBoxDraft: SessionFingerprintTextBoxDraftSnapshot? = nil,
        hasTerminalPanel: Bool = true
    ) -> SessionFingerprintPanelSnapshot {
        SessionFingerprintPanelSnapshot(
            panelId: panelId,
            directory: directory,
            hasRemoteDirectoryReport: hasRemoteDirectoryReport,
            requiresRemoteDirectoryTrust: requiresRemoteDirectoryTrust,
            isManualUnread: false,
            isRestoredUnread: false,
            restoredUnreadContributesToWorkspace: false,
            hasVisibleNotificationIndicator: false,
            notifications: [],
            restorableAgent: nil,
            agentHibernation: nil,
            surfaceResumeBinding: nil,
            hasTerminalPanel: hasTerminalPanel,
            textBoxDraft: textBoxDraft
        )
    }

    private func workspace(
        id: UUID = UUID(),
        customTitle: String = "",
        notifications: [SessionFingerprintNotificationSnapshot] = [],
        panels: [SessionFingerprintPanelSnapshot] = [],
        progress: SessionFingerprintWorkspaceSnapshot.Progress? = nil,
        gitBranch: SessionFingerprintWorkspaceSnapshot.GitBranch? = nil
    ) -> SessionFingerprintWorkspaceSnapshot {
        SessionFingerprintWorkspaceSnapshot(
            id: id,
            groupId: nil,
            focusedPanelId: nil,
            currentDirectory: "/tmp",
            customTitle: customTitle,
            customDescription: "",
            customColor: "",
            isPinned: false,
            panelsCount: panels.count,
            statusEntriesCount: 0,
            metadataBlocksCount: 0,
            logEntriesCount: 0,
            panelDirectoriesCount: 0,
            panelTitlesCount: 0,
            panelPullRequestsCount: 0,
            panelGitBranchesCount: 0,
            surfaceListeningPortsCount: 0,
            hasManualUnread: false,
            workspaceIsUnread: false,
            notifications: notifications,
            panels: panels,
            progress: progress,
            gitBranch: gitBranch
        )
    }

    private func input(
        selectedTabId: UUID? = nil,
        workspaceCount: Int = 1,
        groups: [SessionFingerprintGroupSnapshot] = [],
        workspaces: [SessionFingerprintWorkspaceSnapshot]
    ) -> SessionWorkspaceFingerprintInput {
        SessionWorkspaceFingerprintInput(
            selectedTabId: selectedTabId,
            workspaceCount: workspaceCount,
            groups: groups,
            workspaces: workspaces
        )
    }

    @Test
    func identicalInputsHashIdentically() {
        let ws = workspace(panels: [panel()])
        let a = input(workspaces: [ws])
        let b = input(workspaces: [ws])
        #expect(service.fingerprint(for: a) == service.fingerprint(for: b))
    }

    @Test
    func customTitleChangeChangesFingerprint() {
        let wsId = UUID()
        let base = input(workspaces: [workspace(id: wsId, customTitle: "alpha")])
        let changed = input(workspaces: [workspace(id: wsId, customTitle: "beta")])
        #expect(service.fingerprint(for: base) != service.fingerprint(for: changed))
    }

    @Test
    func groupMetadataChangeChangesFingerprint() {
        let anchor = UUID()
        let groupA = SessionFingerprintGroupSnapshot(
            id: UUID(), name: "g", isCollapsed: false, isPinned: false,
            anchorWorkspaceId: anchor, customColor: "", iconSymbol: ""
        )
        let groupB = SessionFingerprintGroupSnapshot(
            id: groupA.id, name: "g", isCollapsed: true, isPinned: false,
            anchorWorkspaceId: anchor, customColor: "", iconSymbol: ""
        )
        let ws = workspace()
        let base = input(groups: [groupA], workspaces: [ws])
        let changed = input(groups: [groupB], workspaces: [ws])
        #expect(service.fingerprint(for: base) != service.fingerprint(for: changed))
    }

    @Test
    func notificationOrderDoesNotChangeFingerprint() {
        let n1 = notification(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let n2 = notification(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let wsId = UUID()
        let forward = input(workspaces: [workspace(id: wsId, notifications: [n1, n2])])
        let reversed = input(workspaces: [workspace(id: wsId, notifications: [n2, n1])])
        #expect(service.fingerprint(for: forward) == service.fingerprint(for: reversed))
    }

    @Test
    func notificationClickActionChangesFingerprint() {
        let id = UUID()
        let wsId = UUID()
        let plain = input(workspaces: [workspace(id: wsId, notifications: [notification(id: id)])])
        let withAction = input(workspaces: [
            workspace(id: wsId, notifications: [notification(id: id, clickAction: .revealInFinder(path: "/a"))])
        ])
        #expect(service.fingerprint(for: plain) != service.fingerprint(for: withAction))
    }

    @Test
    func terminalPanelDraftDistinguishesFromNonTerminalPanel() {
        let pid = UUID()
        let wsId = UUID()
        let draft = SessionFingerprintTextBoxDraftSnapshot(isActive: true, parts: [
            .init(kindRawValue: "text", text: "hello", attachment: nil)
        ])
        let withDraft = input(workspaces: [
            workspace(id: wsId, panels: [panel(panelId: pid, textBoxDraft: draft, hasTerminalPanel: true)])
        ])
        let nonTerminal = input(workspaces: [
            workspace(id: wsId, panels: [panel(panelId: pid, textBoxDraft: nil, hasTerminalPanel: false)])
        ])
        #expect(service.fingerprint(for: withDraft) != service.fingerprint(for: nonTerminal))
    }

    @Test
    func progressBranchDiffersFromAbsentProgress() {
        let wsId = UUID()
        let withProgress = input(workspaces: [
            workspace(id: wsId, progress: .init(quantizedValue: 500, label: "half"))
        ])
        let withoutProgress = input(workspaces: [workspace(id: wsId, progress: nil)])
        #expect(service.fingerprint(for: withProgress) != service.fingerprint(for: withoutProgress))
    }

    @Test
    func restorableAgentFingerprintMatchesEmbeddedHash() {
        // The standalone restorable-agent fingerprint must equal the contribution
        // the same snapshot makes when embedded, proving the shared helper path.
        let agent = SessionFingerprintRestorableAgentSnapshot(
            kindRawValue: "claude",
            sessionId: "sid",
            workingDirectory: "/w",
            launchCommand: nil
        )
        let a = service.restorableAgentFingerprint(for: agent)
        let b = service.restorableAgentFingerprint(for: agent)
        #expect(a == b)

        let other = SessionFingerprintRestorableAgentSnapshot(
            kindRawValue: "codex",
            sessionId: "sid",
            workingDirectory: "/w",
            launchCommand: nil
        )
        #expect(service.restorableAgentFingerprint(for: other) != a)
        #expect(service.restorableAgentFingerprint(for: nil) != a)
    }
}
