import CmuxMobileSupport
import SwiftUI

/// Terminal utility actions shared by the toolbar menu and Labs switcher sheet.
struct TerminalPickerUtilitiesSection: View {
    let hasActiveBrowser: Bool
    let isChatMode: Bool
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void

    var body: some View {
        #if canImport(UIKit)
        Section {
            if !hasActiveBrowser && !isChatMode {
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
        }
        #endif
    }
}
