import Foundation

extension Workspace {
    static func restoredWorkspaceNameIsVerified(
        _ snapshot: SessionWorkspaceSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot]
    ) -> Bool {
        restoredWorkspaceNameIsVerified(
            snapshot,
            panelSnapshotsById: panelSnapshotsById,
            verificationByPanelId: [:]
        )
    }

    static func restoredWorkspaceNameIsVerified(
        _ snapshot: SessionWorkspaceSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        verificationByPanelId: [UUID: CrashRecoveryVerification]
    ) -> Bool {
        guard snapshot.customTitleSource == .auto,
              let focusedPanelId = snapshot.focusedPanelId,
              let panelSnapshot = panelSnapshotsById[focusedPanelId] else {
            return false
        }
        return restoredPanelNameIsVerified(
            panelSnapshot,
            cachedVerification: verificationByPanelId[focusedPanelId]
        )
    }

    static func restoredPanelNameIsVerified(_ snapshot: SessionPanelSnapshot) -> Bool {
        restoredPanelNameIsVerified(snapshot, cachedVerification: nil)
    }

    static func restoredPanelNameIsVerified(
        _ snapshot: SessionPanelSnapshot,
        cachedVerification: CrashRecoveryVerification?
    ) -> Bool {
        guard snapshot.customTitleSource == .auto else { return false }
        let snapshotRestorableAgent = snapshot.terminal?.agent
        let resumeBinding = resumeBindingForSessionRestore(
            snapshot.terminal?.resumeBinding,
            restorableAgent: snapshotRestorableAgent
        )
        if let cachedVerification {
            guard let expectedFingerprint = restoredPanelVerificationFingerprint(
                restorableAgent: snapshotRestorableAgent,
                resumeBinding: resumeBinding
            ),
                  cachedVerification.fingerprint == expectedFingerprint else {
                return false
            }
            return ResumeFidelityGate().isVerified(cachedVerification.facts)
        }
        if let restorableAgent = restorableAgentForSessionRestore(
            snapshotRestorableAgent,
            resumeBinding: resumeBinding
        ) {
            guard let verification = crashRecoveryVerificationWithoutFilesystemScan(agent: restorableAgent) else {
                return false
            }
            return ResumeFidelityGate().isVerified(verification.facts)
        }
        if let resumeBinding {
            guard let verification = crashRecoveryVerificationWithoutFilesystemScan(binding: resumeBinding) else {
                return false
            }
            return ResumeFidelityGate().isVerified(verification.facts)
        }
        return false
    }

    static func restoredPanelVerificationFingerprint(
        restorableAgent: SessionRestorableAgentSnapshot?,
        resumeBinding: SurfaceResumeBindingSnapshot?
    ) -> CrashRecoveryVerificationFingerprint? {
        if let restorableAgent = restorableAgentForSessionRestore(
            restorableAgent,
            resumeBinding: resumeBinding
        ) {
            return crashRecoveryVerificationFingerprint(agent: restorableAgent)
        }
        if let resumeBinding {
            return crashRecoveryVerificationFingerprint(binding: resumeBinding)
        }
        return nil
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
                panelSnapshotsById: panelSnapshotsById,
                verificationByPanelId: restoredAgentVerificationByPanelId
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
            isVerified: Self.restoredPanelNameIsVerified(
                snapshot,
                cachedVerification: restoredAgentVerificationByPanelId[panelId]
            )
        )
        if restoredPanelName == .neutral, snapshot.customTitleSource == .auto {
            panelTitles.removeValue(forKey: panelId)
        }
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
