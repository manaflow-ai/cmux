import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Terminal rows shared by the toolbar menu and Labs switcher sheet.
struct TerminalPickerTerminalSection: View {
    let rows: [TerminalPickerMenuRow]
    let selectedID: MobileTerminalPreview.ID?
    let hasActiveBrowser: Bool
    let activeBrowserStreamPanelID: String?
    let selectTerminal: (MobileTerminalPreview.ID) -> Void

    var body: some View {
        Section(L10n.string("mobile.terminal.picker.title", defaultValue: "Terminals")) {
            ForEach(rows) { terminal in
                Button {
                    selectTerminal(terminal.id)
                } label: {
                    Label(
                        terminal.name,
                        systemImage: terminal.id == selectedID
                            && !hasActiveBrowser
                            && activeBrowserStreamPanelID == nil
                            ? "checkmark.circle.fill"
                            : "terminal"
                    )
                }
                .accessibilityIdentifier("MobileTerminalMenuItem-\(terminal.id.rawValue)")
            }
        }
    }
}
