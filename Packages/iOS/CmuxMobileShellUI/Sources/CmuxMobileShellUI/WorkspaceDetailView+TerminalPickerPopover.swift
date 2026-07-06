import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

enum TerminalPickerPopoverAction: Equatable {
    case selectTerminal(MobileTerminalPreview.ID)
    case createWorkspace
    case createTerminal
    case openBrowser
    case openTextSheet
    #if DEBUG
    case copyDebugLogs
    #endif
    case openFeedbackComposer
}

extension WorkspaceDetailView {
    var terminalPickerToolbarButton: some View {
        let selection = terminalPickerLiveRows.resolvedTerminalPickerSelection(selectedID: store.selectedTerminalID)
        let rows = terminalPickerRows.isEmpty ? terminalPickerLiveRows : terminalPickerRows

        return Button(action: presentTerminalPickerFromToolbar) {
            Label(
                selection?.name ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "rectangle.stack"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityLabel(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(selection?.name ?? "")
        .popover(isPresented: $isTerminalPickerPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            terminalPickerPopoverContent(rows: rows, selectedID: selection?.id)
        }
        .onChange(of: isTerminalPickerPresented) { _, isPresented in
            guard !isPresented, let action = pendingTerminalPickerAction else { return }
            pendingTerminalPickerAction = nil
            performTerminalPickerPopoverAction(action)
        }
        .onAppear { syncTerminalPickerRows(includeTitleChanges: true) }
        .onChange(of: terminalPickerLiveMembership) { _, _ in syncTerminalPickerRows() }
    }

    func presentTerminalPickerFromToolbar() {
        dismissTerminalKeyboardForChrome()
        syncTerminalPickerRows(includeTitleChanges: true)
        isTerminalPickerPresented = true
    }

    func queueTerminalPickerPopoverAction(_ action: TerminalPickerPopoverAction) {
        pendingTerminalPickerAction = action
        isTerminalPickerPresented = false
    }

    func performTerminalPickerPopoverAction(_ action: TerminalPickerPopoverAction) {
        switch action {
        case .selectTerminal(let terminalID):
            selectTerminalFromPicker(terminalID)
        case .createWorkspace:
            createWorkspaceFromToolbar()
        case .createTerminal:
            createTerminalFromToolbar()
        case .openBrowser:
            openBrowserFromToolbar()
        case .openTextSheet:
            Task { @MainActor in
                await Task.yield()
                openTextSheetFromMenu()
            }
        #if DEBUG
        case .copyDebugLogs:
            copyDebugLogsFromMenu()
        #endif
        case .openFeedbackComposer:
            Task { @MainActor in
                await Task.yield()
                openFeedbackComposerFromMenu()
            }
        }
    }

    private func terminalPickerPopoverContent(
        rows: [TerminalPickerMenuRow],
        selectedID: MobileTerminalPreview.ID?
    ) -> some View {
        List {
            Section(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")) {
                ForEach(rows) { terminal in
                    Button {
                        queueTerminalPickerPopoverAction(.selectTerminal(terminal.id))
                    } label: {
                        Label(
                            terminal.name,
                            systemImage: terminal.id == selectedID && activeBrowser == nil
                                ? "checkmark.circle.fill"
                                : "terminal"
                        )
                    }
                    .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
                }
            }

            Section {
                Button {
                    queueTerminalPickerPopoverAction(.createWorkspace)
                } label: {
                    Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
                }
                .disabled(!canCreateWorkspace)
                .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

                Button {
                    queueTerminalPickerPopoverAction(.createTerminal)
                } label: {
                    Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                }
                .accessibilityIdentifier("MobileNewTerminalMenuItem")

                Button {
                    queueTerminalPickerPopoverAction(.openBrowser)
                } label: {
                    Label(
                        L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                        systemImage: activeBrowser == nil ? "globe" : "checkmark.circle.fill"
                    )
                }
                .accessibilityIdentifier("MobileNewBrowserMenuItem")
            }

            Section {
                if activeBrowser == nil && !isChatMode {
                    Button {
                        queueTerminalPickerPopoverAction(.openTextSheet)
                    } label: {
                        Label(
                            L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                            systemImage: "doc.plaintext"
                        )
                    }
                    .accessibilityIdentifier("MobileViewAsTextMenuItem")
                }

                #if DEBUG
                Button {
                    queueTerminalPickerPopoverAction(.copyDebugLogs)
                } label: {
                    Label(L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"), systemImage: "doc.on.clipboard")
                }
                .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
                #endif

                Button {
                    queueTerminalPickerPopoverAction(.openFeedbackComposer)
                } label: {
                    Label(
                        L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                        systemImage: "paperplane"
                    )
                }
                .accessibilityIdentifier("MobileSendFeedbackMenuItem")
            }
        }
        .listStyle(.insetGrouped)
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 380, minHeight: 260, maxHeight: 420)
        .presentationCompactAdaptation(.popover)
    }
}
