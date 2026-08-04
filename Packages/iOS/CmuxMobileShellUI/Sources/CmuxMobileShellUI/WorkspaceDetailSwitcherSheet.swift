import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Large Labs switcher that presents every surface and workspace action as list rows.
struct WorkspaceDetailSwitcherSheet: View {
    let terminalValue: TerminalPickerMenuValue
    let terminalActions: TerminalPickerMenuActions
    let workspaceValue: WorkspaceTitleMenuContentValue
    let workspaceActions: WorkspaceTitleMenuActions
    let terminalTheme: TerminalTheme
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                TerminalPickerTerminalSection(
                    rows: terminalValue.rows,
                    selectedID: terminalValue.selectedID,
                    hasActiveBrowser: terminalValue.hasActiveBrowser,
                    activeBrowserStreamPanelID: terminalValue.activeBrowserStreamPanelID,
                    selectTerminal: terminalActions.selectTerminal
                )
                TerminalPickerBrowserSection(
                    rows: terminalValue.browserStreamRows,
                    supportsBrowserStream: terminalValue.supportsBrowserStream,
                    activeBrowserStreamPanelID: terminalValue.activeBrowserStreamPanelID,
                    selectBrowserStream: terminalActions.selectBrowserStream
                )
                TerminalPickerCreationSection(
                    canCreateWorkspace: terminalValue.canCreateWorkspace,
                    hasActiveBrowser: terminalValue.hasActiveBrowser,
                    createWorkspace: terminalActions.createWorkspace,
                    createTerminal: terminalActions.createTerminal,
                    openBrowser: terminalActions.openBrowser
                )
                TerminalPickerUtilitiesSection(
                    hasActiveBrowser: terminalValue.hasActiveBrowser,
                    isChatMode: terminalValue.isChatMode,
                    openTextSheet: terminalActions.openTextSheet,
                    copyDebugLogs: terminalActions.copyDebugLogs,
                    sendFeedback: terminalActions.sendFeedback
                )
                WorkspaceTitleMenuContent(
                    value: workspaceValue,
                    actions: workspaceActions
                )
            }
            .scrollContentBackground(.hidden)
            .background(terminalTheme.terminalBackgroundColor)
            .navigationTitle(L10n.string(
                "mobile.workspace.detail.switcherSheet.title",
                defaultValue: "Workspace & Terminals"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done"), action: dismiss)
                }
            }
        }
        .environment(\.colorScheme, terminalTheme.terminalColorScheme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("MobileWorkspaceSwitcherSheet")
    }
}
