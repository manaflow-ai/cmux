import CmuxPanes
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        return CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: self,
            surfaceId: target.surfaceID
        )
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        let surfaceID = surfaceOwnershipTarget(for: sourcePanelId)?.surfaceID
            ?? sourcePanelId
        return !canResolveTerminalPathsAgainstLocalFilesystem(
            surfaceID: surfaceID
        )
    }

    func terminalLinkBrowserProfileID(for sourcePanelId: UUID) -> UUID? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        let profileSourcePanelID: UUID?
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            profileSourcePanelID = effectiveSelectedPanelId(inPane: targetPane)
        } else {
            profileSourcePanelID = target.containerPanelID
        }
        return resolvedNewBrowserProfileID(sourcePanelId: profileSourcePanelID)
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInCmux(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: target.containerPanelID,
            filePath: filePath,
            fallback: fallback
        )
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        let intendedProfileID = terminalLinkBrowserProfileID(for: sourcePanelId)
        let preferredProfileID = intendedProfileID.flatMap { profileID in
            BrowserPrewarmedWebViewPool.shared.hasEntry(url: url, profileID: profileID)
                ? profileID
                : nil
        }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            return newBrowserSurface(
                inPane: targetPane,
                url: url,
                focus: true,
                preferredProfileID: preferredProfileID
            ) != nil
        }
        return newBrowserSplit(
            from: target.containerPanelID,
            orientation: .horizontal,
            url: url,
            preferredProfileID: preferredProfileID
        ) != nil
    }
}
