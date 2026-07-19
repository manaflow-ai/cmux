import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

struct WorkspaceSurfaceActionsMenu: View {
    let terminalTheme: TerminalTheme
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let isChatMode: Bool
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let openBrowser: () -> Void
    let openTextSheet: () -> Void
    let copyDebugLogs: () -> Void
    let sendFeedback: () -> Void

    var body: some View {
        Menu {
            Section {
                Button(action: createWorkspace) {
                    Label(
                        L10n.string("mobile.workspace.new", defaultValue: "New Workspace"),
                        systemImage: "plus.square.on.square"
                    )
                }
                .disabled(!canCreateWorkspace)
                .accessibilityIdentifier("MobileNewWorkspaceMenuItem")

                Button(action: createTerminal) {
                    Label(L10n.string("mobile.terminal.new", defaultValue: "New Terminal"), systemImage: "plus")
                }
                .accessibilityIdentifier("MobileNewTerminalMenuItem")

                Button(action: openBrowser) {
                    Label(
                        L10n.string("mobile.browser.new", defaultValue: "New Browser"),
                        systemImage: hasActiveBrowser ? "checkmark.circle.fill" : "globe"
                    )
                }
                .accessibilityIdentifier("MobileNewBrowserMenuItem")
            }

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
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .accessibilityLabel(L10n.string("mobile.surfaceDeck.actions", defaultValue: "Workspace Actions"))
        .accessibilityIdentifier("MobileWorkspaceActionsMenu")
    }
}
