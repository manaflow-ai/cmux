public import CmuxNextSettings

/// `agentPane.editedFiles.*` (``AgentPaneEditedFilesSetting``) reaches the page as the
/// `editedFiles` event, read by the page's turnChanges/settings.ts.
extension AgentPageEvent {
    /// The edited-files card's settings: `{show, maxRows, scope}`.
    public static func editedFiles(_ setting: AgentPaneEditedFilesSetting) -> AgentPageEvent {
        AgentPageEvent(kind: "editedFiles", value: setting.pageValue)
    }
}

extension AgentPaneView {
    /// The script that gives a loaded old-host page the edited-files card's settings.
    static func editedFilesScript(_ setting: AgentPaneEditedFilesSetting) -> String {
        "window.cmuxAcpmuxEditedFiles?.(\(setting.pageValue.compactText));"
    }

    /// Pushes ``editedFiles`` to the page.
    func applyEditedFiles() {
        deliver([.editedFiles(editedFiles)], scripts: [Self.editedFilesScript(editedFiles)])
    }
}
