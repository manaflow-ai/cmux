import CmuxMobileSupport
import SwiftUI

/// Surface-creation actions shared by the toolbar menu and Labs switcher sheet.
struct TerminalPickerCreationSection: View {
    let canCreateWorkspace: Bool
    let hasActiveBrowser: Bool
    let createWorkspace: () -> Void
    let createTerminal: () -> Void
    let openBrowser: () -> Void

    var body: some View {
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
                Label(
                    L10n.string("mobile.terminal.new", defaultValue: "New Terminal"),
                    systemImage: "plus"
                )
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
    }
}
