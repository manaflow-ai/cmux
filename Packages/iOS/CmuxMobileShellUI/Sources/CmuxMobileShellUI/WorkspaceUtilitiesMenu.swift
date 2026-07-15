import CmuxMobileSupport
import SwiftUI

/// Workspace-level utilities that remain in the top-right toolbar.
struct WorkspaceUtilitiesMenu: View {
    let showsViewAsText: Bool
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void

    var body: some View {
        Menu {
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
        .foregroundStyle(TerminalPalette.foreground)
        .accessibilityLabel(
            L10n.string("mobile.workspace.utilitiesMenu", defaultValue: "Workspace Utilities")
        )
        .accessibilityIdentifier("MobileWorkspaceUtilitiesMenu")
    }
}
