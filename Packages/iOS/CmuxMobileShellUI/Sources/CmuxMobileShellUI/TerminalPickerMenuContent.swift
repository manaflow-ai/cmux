import SwiftUI

/// Reusable, snapshot-only content for workspace surface menus and sheets.
struct TerminalPickerMenuContent: View {
    enum Mode: Equatable {
        case full
        case terminalsOnly
        case utilitiesOnly
    }

    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions
    let mode: Mode

    init(
        value: TerminalPickerMenuValue,
        actions: TerminalPickerMenuActions,
        mode: Mode = .full
    ) {
        self.value = value
        self.actions = actions
        self.mode = mode
    }

    @ViewBuilder
    var body: some View {
        switch mode {
        case .full:
            TerminalPickerTerminalSection(
                rows: value.rows,
                selectedID: value.selectedID,
                hasActiveBrowser: value.hasActiveBrowser,
                activeBrowserStreamPanelID: value.activeBrowserStreamPanelID,
                selectTerminal: actions.selectTerminal
            )
            TerminalPickerBrowserSection(
                rows: value.browserStreamRows,
                supportsBrowserStream: value.supportsBrowserStream,
                activeBrowserStreamPanelID: value.activeBrowserStreamPanelID,
                selectBrowserStream: actions.selectBrowserStream
            )
            TerminalPickerCreationSection(
                canCreateWorkspace: value.canCreateWorkspace,
                hasActiveBrowser: value.hasActiveBrowser,
                createWorkspace: actions.createWorkspace,
                createTerminal: actions.createTerminal,
                openBrowser: actions.openBrowser
            )
            TerminalPickerUtilitiesSection(
                hasActiveBrowser: value.hasActiveBrowser,
                isChatMode: value.isChatMode,
                openTextSheet: actions.openTextSheet,
                copyDebugLogs: actions.copyDebugLogs,
                sendFeedback: actions.sendFeedback
            )
        case .terminalsOnly:
            TerminalPickerTerminalSection(
                rows: value.rows,
                selectedID: value.selectedID,
                hasActiveBrowser: value.hasActiveBrowser,
                activeBrowserStreamPanelID: value.activeBrowserStreamPanelID,
                selectTerminal: actions.selectTerminal
            )
        case .utilitiesOnly:
            TerminalPickerBrowserSection(
                rows: value.browserStreamRows,
                supportsBrowserStream: value.supportsBrowserStream,
                activeBrowserStreamPanelID: value.activeBrowserStreamPanelID,
                selectBrowserStream: actions.selectBrowserStream
            )
            TerminalPickerCreationSection(
                canCreateWorkspace: value.canCreateWorkspace,
                hasActiveBrowser: value.hasActiveBrowser,
                createWorkspace: actions.createWorkspace,
                createTerminal: actions.createTerminal,
                openBrowser: actions.openBrowser
            )
            TerminalPickerUtilitiesSection(
                hasActiveBrowser: value.hasActiveBrowser,
                isChatMode: value.isChatMode,
                openTextSheet: actions.openTextSheet,
                copyDebugLogs: actions.copyDebugLogs,
                sendFeedback: actions.sendFeedback
            )
        }
    }
}
