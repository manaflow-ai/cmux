import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalPickerSheet: View {
    let workspace: MobileWorkspacePreview
    let selectedTerminalID: MobileTerminalPreview.ID?
    let isBrowserActive: Bool
    let canCreateWorkspace: Bool
    let canCloseTerminals: Bool
    let selectTerminal: (MobileTerminalPreview.ID) -> Void
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let openBrowser: () -> Void
    let closeTerminal: (MobileTerminalPreview.ID) -> Void
    let openTextSheet: (() -> Void)?
    #if DEBUG
    let copyDebugLogs: (() -> Void)?
    #endif
    let openFeedbackComposer: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                terminalSection
                createSection
                toolSection
            }
            .navigationTitle(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileTerminalPickerDoneButton")
                }
            }
        }
    }

    @ViewBuilder
    private var terminalSection: some View {
        Section(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")) {
            ForEach(workspace.terminals) { terminal in
                Button {
                    performAndDismiss { selectTerminal(terminal.id) }
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == selectedTerminalID && !isBrowserActive
                            ? "checkmark.circle.fill"
                            : "terminal"
                    )
                }
                .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if canDeleteTerminalRows {
                        Button(role: .destructive) {
                            closeTerminal(terminal.id)
                        } label: {
                            Label(L10n.string("mobile.common.delete", defaultValue: "Delete"), systemImage: "trash")
                        }
                        .tint(.red)
                        .accessibilityIdentifier("MobileTerminalDeleteSwipeButton-\(terminal.id.rawValue)")
                    }
                }
            }
        }
    }

    private var createSection: some View {
        Section {
            Button {
                performAndDismiss(createWorkspace)
            } label: {
                Label(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"), systemImage: "plus.square.on.square")
            }
            .disabled(!canCreateWorkspace)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            Button {
                performAndDismiss(createTerminal)
            } label: {
                Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
            }
            .accessibilityIdentifier("MobileNewTerminalMenuItem")

            Button {
                performAndDismiss(openBrowser)
            } label: {
                Label(
                    L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                    systemImage: isBrowserActive ? "checkmark.circle.fill" : "globe"
                )
            }
            .accessibilityIdentifier("MobileNewBrowserMenuItem")
        }
    }

    @ViewBuilder
    private var toolSection: some View {
        if openTextSheet != nil || debugLogsAvailable || openFeedbackComposer != nil {
            Section {
                if let openTextSheet {
                    Button {
                        performAndDismiss(openTextSheet)
                    } label: {
                        Label(
                            L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                            systemImage: "doc.plaintext"
                        )
                    }
                    .accessibilityIdentifier("MobileViewAsTextMenuItem")
                }

                #if DEBUG
                if let copyDebugLogs {
                    Button {
                        performAndDismiss(copyDebugLogs)
                    } label: {
                        Label(
                            L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
                            systemImage: "doc.on.clipboard"
                        )
                    }
                    .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
                }
                #endif

                if let openFeedbackComposer {
                    Button {
                        performAndDismiss(openFeedbackComposer)
                    } label: {
                        Label(
                            L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                            systemImage: "paperplane"
                        )
                    }
                    .accessibilityIdentifier("MobileSendFeedbackMenuItem")
                }
            }
        }
    }

    private var canDeleteTerminalRows: Bool {
        canCloseTerminals && workspace.terminals.count > 1
    }

    private var debugLogsAvailable: Bool {
        #if DEBUG
        return copyDebugLogs != nil
        #else
        return false
        #endif
    }

    private func performAndDismiss(_ action: () -> Void) {
        dismiss()
        action()
    }
}
