import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

#if os(iOS)
extension WorkspaceDetailView {
    @ViewBuilder
    var workspaceDetailTitleToolbarControl: some View {
        switch displaySettings.workspaceDetailLabVariant {
        case .none, .some(.inlineTabs):
            workspaceTitleToolbarMenu
        case .some(.titleSwitcher):
            WorkspaceDetailSurfaceTitleMenu(
                titleValue: workspaceTitleMenuValue(
                    hasTrailingCluster: shouldShowChatToggle,
                    hasChatToggle: false
                ),
                terminalValue: terminalPickerMenuValue,
                terminalActions: terminalPickerMenuActions,
                workspaceValue: workspaceTitleContentValue(
                    showsRenameAlongsideCustomization: true
                ),
                workspaceActions: workspaceTitleActions,
                mode: .full,
                includesWorkspaceActions: true,
                labelStyle: .workspaceFirst
            )
            .equatable()
            .simultaneousGesture(TapGesture().onEnded {
                syncTerminalPickerRows(includeTitleChanges: true)
            })
            .onAppear { syncTerminalPickerRows(includeTitleChanges: true) }
            .onChange(of: terminalPickerLiveMembership) { _, _ in syncTerminalPickerRows() }
        case .some(.terminalFocus):
            WorkspaceDetailSurfaceTitleMenu(
                titleValue: workspaceTitleMenuValue(
                    hasTrailingCluster: true,
                    hasChatToggle: shouldShowChatToggle
                ),
                terminalValue: terminalPickerMenuValue,
                terminalActions: terminalPickerMenuActions,
                workspaceValue: workspaceTitleContentValue(
                    showsRenameAlongsideCustomization: true
                ),
                workspaceActions: workspaceTitleActions,
                mode: .terminalsOnly,
                includesWorkspaceActions: false,
                labelStyle: .terminalFirst
            )
            .equatable()
            .simultaneousGesture(TapGesture().onEnded {
                syncTerminalPickerRows(includeTitleChanges: true)
            })
            .onAppear { syncTerminalPickerRows(includeTitleChanges: true) }
            .onChange(of: terminalPickerLiveMembership) { _, _ in syncTerminalPickerRows() }
        case .some(.switcherSheet):
            WorkspaceDetailTitleButton(
                titleValue: workspaceTitleMenuValue(
                    hasTrailingCluster: true,
                    hasChatToggle: shouldShowChatToggle
                ),
                action: presentWorkspaceSwitcherSheet
            )
            .equatable()
        case .some(.titleStepper):
            WorkspaceDetailSurfaceTitleMenu(
                titleValue: workspaceTitleMenuValue(
                    hasTrailingCluster: true,
                    hasChatToggle: true
                ),
                terminalValue: terminalPickerMenuValue,
                terminalActions: terminalPickerMenuActions,
                workspaceValue: workspaceTitleContentValue(
                    showsRenameAlongsideCustomization: true
                ),
                workspaceActions: workspaceTitleActions,
                mode: .full,
                includesWorkspaceActions: true,
                labelStyle: .workspaceFirst
            )
            .equatable()
            .simultaneousGesture(TapGesture().onEnded {
                syncTerminalPickerRows(includeTitleChanges: true)
            })
            .onAppear { syncTerminalPickerRows(includeTitleChanges: true) }
            .onChange(of: terminalPickerLiveMembership) { _, _ in syncTerminalPickerRows() }
        }
    }

    @ViewBuilder
    var workspaceDetailTrailingToolbarControl: some View {
        switch displaySettings.workspaceDetailLabVariant {
        case .none, .some(.inlineTabs):
            toolbarTrailingCluster
        case .some(.titleSwitcher):
            if shouldShowChatToggle {
                chatToggleButton
                    .frame(width: 44, height: 44)
            }
        case .some(.terminalFocus):
            HStack(spacing: 8) {
                if shouldShowChatToggle {
                    chatToggleButton
                        .frame(width: 44, height: 44)
                }
                WorkspaceDetailOverflowMenu(
                    terminalValue: terminalPickerMenuValue,
                    terminalActions: terminalPickerMenuActions,
                    workspaceValue: workspaceTitleContentValue(
                        showsRenameAlongsideCustomization: true
                    ),
                    workspaceActions: workspaceTitleActions,
                    terminalTheme: store.activeTerminalTheme
                )
                .equatable()
                .simultaneousGesture(TapGesture().onEnded {
                    syncTerminalPickerRows(includeTitleChanges: true)
                })
                .onAppear { syncTerminalPickerRows(includeTitleChanges: true) }
                .onChange(of: terminalPickerLiveMembership) { _, _ in syncTerminalPickerRows() }
            }
            .frame(width: shouldShowChatToggle ? 96 : 44, height: 44, alignment: .trailing)
        case .some(.switcherSheet):
            HStack(spacing: 8) {
                if shouldShowChatToggle {
                    chatToggleButton
                        .frame(width: 44, height: 44)
                }
                Button(action: createTerminalFromToolbar) {
                    Label(
                        L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                        systemImage: "plus"
                    )
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                }
                .foregroundStyle(store.activeTerminalTheme.terminalChromeForegroundColor)
                .accessibilityIdentifier("MobileWorkspaceLabQuickNewTerminalButton")
            }
            .frame(width: shouldShowChatToggle ? 96 : 44, height: 44, alignment: .trailing)
        case .some(.titleStepper):
            HStack(spacing: 8) {
                if shouldShowChatToggle {
                    chatToggleButton
                        .frame(width: 44, height: 44)
                }
                WorkspaceTerminalStepper(
                    canStep: terminalPickerLiveRows.count > 1,
                    terminalTheme: store.activeTerminalTheme,
                    selectPrevious: { selectAdjacentTerminal(offset: -1) },
                    selectNext: { selectAdjacentTerminal(offset: 1) }
                )
                .equatable()
            }
            .frame(height: 44, alignment: .trailing)
        }
    }

    @ViewBuilder
    var workspaceDetailLabTopInset: some View {
        if displaySettings.workspaceDetailLabVariant == .inlineTabs {
            WorkspaceInlineTerminalStrip(
                rows: terminalPickerLiveRows,
                selectedID: activeSurface == .terminal ? selectedTerminal?.id : nil,
                terminalTheme: store.activeTerminalTheme,
                select: selectTerminalFromPicker
            )
        }
    }

    var workspaceDetailSwitcherSheet: some View {
        WorkspaceDetailSwitcherSheet(
            terminalValue: terminalPickerMenuValue,
            terminalActions: TerminalPickerMenuActions(
                selectTerminal: { requestWorkspaceSwitcherSheetAction(.selectTerminal($0)) },
                createWorkspace: { requestWorkspaceSwitcherSheetAction(.createWorkspace) },
                createTerminal: { requestWorkspaceSwitcherSheetAction(.createTerminal) },
                openBrowser: { requestWorkspaceSwitcherSheetAction(.openBrowser) },
                selectBrowserStream: {
                    requestWorkspaceSwitcherSheetAction(.selectBrowserStream($0))
                },
                openTextSheet: { requestWorkspaceSwitcherSheetAction(.openTextSheet) },
                copyDebugLogs: { requestWorkspaceSwitcherSheetAction(.copyDebugLogs) },
                sendFeedback: { requestWorkspaceSwitcherSheetAction(.sendFeedback) }
            ),
            workspaceValue: workspaceTitleContentValue(
                showsRenameAlongsideCustomization: true
            ),
            workspaceActions: WorkspaceTitleMenuActions(
                presentCustomization: {
                    requestWorkspaceSwitcherSheetAction(.customizeWorkspace)
                },
                presentRename: { requestWorkspaceSwitcherSheetAction(.renameWorkspace) },
                toggleReadState: { requestWorkspaceSwitcherSheetAction(.toggleReadState) },
                requestClose: { requestWorkspaceSwitcherSheetAction(.closeWorkspace) }
            ),
            terminalTheme: store.activeTerminalTheme,
            dismiss: { isWorkspaceSwitcherSheetPresented = false }
        )
    }

    private var terminalPickerMenuValue: TerminalPickerMenuValue {
        TerminalPickerMenuValue(
            liveTerminals: workspace.terminals,
            snapshotRows: terminalPickerRows,
            selectedID: store.selectedTerminalID,
            canCreateWorkspace: canCreateWorkspace,
            hasActiveBrowser: activeBrowser != nil,
            isChatMode: isChatMode,
            browserStreamRows: browserStreamStore.panels(in: workspace.rpcWorkspaceID.rawValue).map(
                BrowserStreamPickerRow.init
            ),
            supportsBrowserStream: store.supportsBrowserStream,
            activeBrowserStreamPanelID: activeBrowserStream?.id
        )
    }

    private var terminalPickerMenuActions: TerminalPickerMenuActions {
        TerminalPickerMenuActions(
            selectTerminal: selectTerminalFromPicker,
            createWorkspace: createWorkspaceFromToolbar,
            createTerminal: createTerminalFromToolbar,
            openBrowser: openBrowserFromToolbar,
            selectBrowserStream: selectBrowserStreamFromToolbar,
            openTextSheet: openTextSheetFromMenu,
            copyDebugLogs: {
                #if DEBUG
                copyDebugLogsFromMenu()
                #endif
            },
            sendFeedback: openFeedbackComposerFromMenu
        )
    }

    private var workspaceTitleActions: WorkspaceTitleMenuActions {
        WorkspaceTitleMenuActions(
            presentCustomization: presentCustomizationFromMenu,
            presentRename: presentRenameFromMenu,
            toggleReadState: toggleWorkspaceReadStateFromMenu,
            requestClose: requestCloseWorkspaceFromMenu
        )
    }

    private func workspaceTitleMenuValue(
        hasTrailingCluster: Bool,
        hasChatToggle: Bool
    ) -> WorkspaceTitleMenuValue {
        WorkspaceTitleMenuValue(
            contentWidth: contentWidth,
            hasBackButton: backButtonConfiguration != nil,
            hasTrailingCluster: hasTrailingCluster,
            hasChatToggle: hasChatToggle,
            isEnabled: true,
            workspaceName: workspace.name,
            hasUnread: workspace.hasUnread,
            canCustomizeWorkspace: customizeWorkspace != nil,
            canRenameWorkspace: renameWorkspace != nil,
            canToggleReadState: setWorkspaceUnread != nil,
            canCloseWorkspace: closeWorkspace != nil,
            labelToken: toolbarTitleLabelToken,
            terminalTheme: store.activeTerminalTheme
        )
    }

    private func workspaceTitleContentValue(
        showsRenameAlongsideCustomization: Bool
    ) -> WorkspaceTitleMenuContentValue {
        WorkspaceTitleMenuContentValue(
            workspaceName: workspace.name,
            hasUnread: workspace.hasUnread,
            canCustomizeWorkspace: customizeWorkspace != nil,
            canRenameWorkspace: renameWorkspace != nil,
            canToggleReadState: setWorkspaceUnread != nil,
            canCloseWorkspace: closeWorkspace != nil,
            showsRenameAlongsideCustomization: showsRenameAlongsideCustomization
        )
    }

    private func presentWorkspaceSwitcherSheet() {
        dismissTerminalKeyboardForChrome()
        pendingWorkspaceSwitcherSheetAction = nil
        isWorkspaceSwitcherSheetPresented = true
    }

    private func requestWorkspaceSwitcherSheetAction(_ action: WorkspaceDetailSheetAction) {
        pendingWorkspaceSwitcherSheetAction = action
        isWorkspaceSwitcherSheetPresented = false
    }

    func completeWorkspaceSwitcherSheetAction() {
        guard let action = pendingWorkspaceSwitcherSheetAction else { return }
        pendingWorkspaceSwitcherSheetAction = nil
        switch action {
        case .selectTerminal(let terminalID):
            selectTerminalFromPicker(terminalID)
        case .createWorkspace:
            createWorkspaceFromToolbar()
        case .createTerminal:
            createTerminalFromToolbar()
        case .openBrowser:
            openBrowserFromToolbar()
        case .selectBrowserStream(let panelID):
            selectBrowserStreamFromToolbar(panelID)
        case .openTextSheet:
            openTextSheetFromMenu()
        case .copyDebugLogs:
            #if DEBUG
            copyDebugLogsFromMenu()
            #endif
        case .sendFeedback:
            openFeedbackComposerFromMenu()
        case .customizeWorkspace:
            presentCustomizationFromMenu()
        case .renameWorkspace:
            presentRenameFromMenu()
        case .toggleReadState:
            toggleWorkspaceReadStateFromMenu()
        case .closeWorkspace:
            requestCloseWorkspaceFromMenu()
        }
    }

    private func selectAdjacentTerminal(offset: Int) {
        let rows = terminalPickerLiveRows
        guard rows.count > 1 else { return }
        let currentIndex = rows.firstIndex { $0.id == selectedTerminal?.id } ?? 0
        let nextIndex = (currentIndex + offset + rows.count) % rows.count
        selectTerminalFromPicker(rows[nextIndex].id)
    }
}
#endif
