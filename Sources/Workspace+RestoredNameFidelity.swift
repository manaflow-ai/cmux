import Foundation

extension Workspace {
    static func restoredWorkspaceNameIsVerified(
        _ snapshot: SessionWorkspaceSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot]
    ) -> Bool {
        guard snapshot.customTitleSource == .auto,
              let focusedPanelId = snapshot.focusedPanelId,
              let panelSnapshot = panelSnapshotsById[focusedPanelId] else {
            return false
        }
        return restoredPanelNameIsVerified(panelSnapshot)
    }

    static func restoredPanelNameIsVerified(_ snapshot: SessionPanelSnapshot) -> Bool {
        guard snapshot.customTitleSource == .auto else { return false }
        let snapshotRestorableAgent = snapshot.terminal?.agent
        let resumeBinding = resumeBindingForSessionRestore(
            snapshot.terminal?.resumeBinding,
            restorableAgent: snapshotRestorableAgent
        )
        if let restorableAgent = restorableAgentForSessionRestore(
            snapshotRestorableAgent,
            resumeBinding: resumeBinding
        ) {
            return ResumeFidelityGate().isVerified(
                crashRecoveryVerification(agent: restorableAgent).facts
            )
        }
        if let resumeBinding {
            return ResumeFidelityGate().isVerified(
                crashRecoveryVerification(binding: resumeBinding).facts
            )
        }
        return false
    }

    static func restoredName(
        persistedTitle: String?,
        source: CustomTitleSource?,
        isVerified: Bool
    ) -> RestoredName {
        RestoredNameResolver().resolve(
            persistedTitle: persistedTitle,
            source: source,
            isVerified: isVerified
        )
    }

    static func restoredDisplayName(_ restoredName: RestoredName, processTitle: String) -> String {
        switch restoredName {
        case .keepUserTitle(let title), .applyVerifiedSummary(let title):
            return title
        case .neutral:
            return processTitle
        }
    }

    func applyRestoredWorkspaceName(
        from snapshot: SessionWorkspaceSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot]
    ) {
        let restoredWorkspaceName = Self.restoredName(
            persistedTitle: snapshot.customTitle,
            source: snapshot.customTitleSource,
            isVerified: Self.restoredWorkspaceNameIsVerified(
                snapshot,
                panelSnapshotsById: panelSnapshotsById
            )
        )
        applyProcessTitle(snapshot.processTitle)
        applyRestoredWorkspaceName(restoredWorkspaceName)
    }

    func applyRestoredWorkspaceName(_ restoredName: RestoredName) {
        switch restoredName {
        case .keepUserTitle(let title):
            setCustomTitle(title, source: .user)
        case .applyVerifiedSummary(let title):
            setCustomTitle(title, source: .auto)
        case .neutral:
            setCustomTitle(nil, source: .user)
        }
    }

    func applyRestoredPanelName(from snapshot: SessionPanelSnapshot, toPanelId panelId: UUID) {
        let restoredPanelName = Self.restoredName(
            persistedTitle: snapshot.customTitle,
            source: snapshot.customTitleSource,
            isVerified: Self.restoredPanelNameIsVerified(snapshot)
        )
        applyRestoredPanelName(restoredPanelName, toPanelId: panelId)
    }

    func applyRestoredPanelName(_ restoredName: RestoredName, toPanelId panelId: UUID) {
        switch restoredName {
        case .keepUserTitle(let title):
            setPanelCustomTitle(panelId: panelId, title: title, source: .user)
        case .applyVerifiedSummary(let title):
            setPanelCustomTitle(panelId: panelId, title: title, source: .auto)
        case .neutral:
            setPanelCustomTitle(panelId: panelId, title: nil, source: .user)
        }
    }
}
