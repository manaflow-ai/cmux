import CmuxMobileShellModel

extension WorkspaceDetailView {
    enum TerminalPickerAction {
        case selectTerminal(MobileTerminalPreview.ID)
        case createWorkspace
        case createTerminal
        case openBrowser
        case openTextSheet
        case copyDebugLogs
        case openFeedbackComposer
    }

    var hasTitleMenuActions: Bool {
        workspace.actionCapabilities.supportsWorkspaceActions
            || workspace.actionCapabilities.supportsReadStateActions
            || closeWorkspace != nil
    }

    var terminalPickerDebugCopyLogsAction: (() -> Void)? {
        #if DEBUG
        return { queueTerminalPickerAction(.copyDebugLogs) }
        #else
        return nil
        #endif
    }

    func closeTerminalFromPicker(_ terminalID: MobileTerminalPreview.ID) {
        closeTerminal?(terminalID)
    }

    func queueTerminalPickerAction(_ action: TerminalPickerAction) {
        pendingTerminalPickerAction = action
    }

    func performPendingTerminalPickerActionIfNeeded() {
        guard let pendingTerminalPickerAction else { return }
        self.pendingTerminalPickerAction = nil
        switch pendingTerminalPickerAction {
        case .selectTerminal(let terminalID):
            selectTerminalFromPicker(terminalID)
        case .createWorkspace:
            createWorkspaceFromToolbar()
        case .createTerminal:
            createTerminalFromToolbar()
        case .openBrowser:
            openBrowserFromToolbar()
        #if canImport(UIKit)
        case .openTextSheet:
            openTextSheetFromMenu()
        #else
        case .openTextSheet:
            break
        #endif
        #if canImport(UIKit) && DEBUG
        case .copyDebugLogs:
            copyDebugLogsFromMenu()
        #else
        case .copyDebugLogs:
            break
        #endif
        #if canImport(UIKit)
        case .openFeedbackComposer:
            openFeedbackComposerFromMenu()
        #else
        case .openFeedbackComposer:
            break
        #endif
        }
    }
}
