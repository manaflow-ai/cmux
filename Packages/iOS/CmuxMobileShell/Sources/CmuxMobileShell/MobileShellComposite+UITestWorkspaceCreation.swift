internal import CmuxMobileSupport
internal import CmuxMobileShellModel

extension MobileShellComposite {
    func createLocalWorkspaceWithoutTerminalForDelayedUITestIfNeeded() -> Bool {
        #if DEBUG
        guard UITestConfig.workspaceDetailCreateDelayedTerminalPreviewEnabled else {
            return false
        }
        let nextIndex = workspaces.count + 1
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(nextIndex)"),
            name: L10n.workspaceName(index: nextIndex),
            terminals: []
        )
        mutateForegroundWorkspaces { $0.append(workspace) }
        selectedWorkspaceID = workspace.id
        selectedTerminalID = nil
        return true
        #else
        return false
        #endif
    }
}
