import CmuxMobileSupport
import SwiftUI

/// Snapshot-isolated native menu for switching the active workspace surface.
struct TerminalPickerMenu: View, Equatable {
    let value: TerminalPickerMenuValue
    let actions: TerminalPickerMenuActions
    #if DEBUG
    private let diagnostics = TerminalPickerMenuDiagnostics()
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.value == rhs.value
    }

    var body: some View {
        Menu {
            instrumentedMenuContent
        } label: {
            Label(
                value.selectedName ?? L10n.string("mobile.terminal.select", defaultValue: "Terminal"),
                systemImage: "rectangle.stack"
            )
            .labelStyle(.iconOnly)
        }
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityLabel(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals"))
        .accessibilityIdentifier("MobileTerminalDropdown")
        .accessibilityValue(value.selectedName ?? "")
    }

    @ViewBuilder
    private var instrumentedMenuContent: some View {
        #if DEBUG
        let _ = diagnostics.recordContentBuilderEvaluation(rowCount: value.rows.count)
        #endif
        menuContent
    }

    @ViewBuilder
    private var menuContent: some View {
        Section(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")) {
            ForEach(value.rows) { terminal in
                Button {
                    actions.selectTerminal(terminal.id)
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == value.selectedID && !value.hasActiveBrowser
                            ? "checkmark.circle.fill"
                            : "terminal"
                    )
                }
                .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
            }
        }

        Section {
            Button(action: actions.createWorkspace) {
                Label(
                    L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                    systemImage: "plus.square.on.square"
                )
            }
            .disabled(!value.canCreateWorkspace)
            .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

            Button(action: actions.createTerminal) {
                Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
            }
            .accessibilityIdentifier("MobileNewTerminalMenuItem")

            Button(action: actions.openBrowser) {
                Label(
                    L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                    systemImage: value.hasActiveBrowser ? "checkmark.circle.fill" : "globe"
                )
            }
            .accessibilityIdentifier("MobileNewBrowserMenuItem")
        }

        #if canImport(UIKit)
        Section {
            if !value.hasActiveBrowser && !value.isChatMode {
                Button(action: actions.openTextSheet) {
                    Label(
                        L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                        systemImage: "doc.plaintext"
                    )
                }
                .accessibilityIdentifier("MobileViewAsTextMenuItem")
            }

            #if DEBUG
            Button(action: actions.copyDebugLogs) {
                Label(
                    L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
                    systemImage: "doc.on.clipboard"
                )
            }
            .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
            #endif

            Button(action: actions.sendFeedback) {
                Label(
                    L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                    systemImage: "paperplane"
                )
            }
            .accessibilityIdentifier("MobileSendFeedbackMenuItem")
        }
        #endif
    }
}
