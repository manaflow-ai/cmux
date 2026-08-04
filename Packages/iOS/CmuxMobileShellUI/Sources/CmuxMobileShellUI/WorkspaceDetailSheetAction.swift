import CmuxMobileShellModel

/// Deferred action performed after the Labs switcher sheet finishes dismissing.
enum WorkspaceDetailSheetAction: Equatable {
    case selectTerminal(MobileTerminalPreview.ID)
    case createWorkspace
    case createTerminal
    case openBrowser
    case selectBrowserStream(String)
    case openTextSheet
    case copyDebugLogs
    case sendFeedback
    case customizeWorkspace
    case renameWorkspace
    case toggleReadState
    case closeWorkspace
}
