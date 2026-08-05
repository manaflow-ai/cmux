import CMUXMobileCore
import CmuxMobileSupport
import SwiftUI

/// Workspace-level utilities that remain in the top-right toolbar.
struct WorkspaceUtilitiesMenu: View {
    let showsViewAsText: Bool
    let showsPaneMap: Bool
    var browserStreamRows: [BrowserStreamPickerRow] = []
    var supportsBrowserStream = true
    var activeBrowserStreamPanelID: String?
    let terminalTheme: TerminalTheme
    var selectBrowserStream: (String) -> Void = { _ in }
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

            if supportsBrowserStream {
                if !browserStreamRows.isEmpty {
                    Section(L10n.string("mobile.browserStream.menuTitle", defaultValue: "Mac Browsers")) {
                        ForEach(browserStreamRows) { panel in
                            Button { selectBrowserStream(panel.id) } label: {
                                Label(
                                    panel.label,
                                    systemImage: panel.id == activeBrowserStreamPanelID
                                        ? "checkmark.circle.fill"
                                        : "globe"
                                )
                            }
                            .accessibilityIdentifier("BrowserStreamMenuItem-\(panel.id)")
                        }
                    }
                }
            } else {
                Section(L10n.string("mobile.browserStream.menuTitle", defaultValue: "Mac Browsers")) {
                    Label(
                        L10n.string(
                            "mobile.macUpdateHint.browserStream",
                            defaultValue: "Update cmux on your Mac to stream browser panes"
                        ),
                        systemImage: "arrow.down.circle"
                    )
                    .accessibilityIdentifier("BrowserStreamMacUpdateHint")
                }
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
