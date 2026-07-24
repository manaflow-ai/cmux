import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Workspace-level utilities that remain in the top-right toolbar.
struct WorkspaceUtilitiesMenu: View {
    let showsViewAsText: Bool
    let showsPaneMap: Bool
    let terminalTheme: TerminalTheme
    let presentPaneMap: () -> Void
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void

    var body: some View {
        Menu {
            if showsPaneMap {
                Button(action: presentPaneMap) {
                    Label(
                        L10n.string("mobile.surfaceDeck.paneMap", defaultValue: "Pane Map"),
                        systemImage: "rectangle.split.2x2"
                    )
                }
                .accessibilityIdentifier("MobilePaneMapMenuItem")
            }

            if showsViewAsText {
                Button(action: openTextSheet) {
                    Label(
                        L10n.string("mobile.terminal.viewAsText", defaultValue: "View as Text"),
                        systemImage: "doc.plaintext"
                    )
                }
                .accessibilityIdentifier("MobileViewAsTextMenuItem")
            }

            #if DEBUG
            Button(action: copyDebugLogs) {
                Label(
                    L10n.string("mobile.debug.copyLogs", defaultValue: "Copy Debug Logs"),
                    systemImage: "doc.on.clipboard"
                )
            }
            .accessibilityIdentifier("MobileCopyDebugLogsMenuItem")
            #endif

            Button(action: sendFeedback) {
                Label(
                    L10n.string("mobile.feedback.send", defaultValue: "Send Feedback"),
                    systemImage: "paperplane"
                )
            }
            .accessibilityIdentifier("MobileSendFeedbackMenuItem")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(
            L10n.string("mobile.workspace.utilitiesMenu", defaultValue: "Workspace Utilities")
        )
        .accessibilityIdentifier("MobileWorkspaceUtilitiesMenu")
    }
}
