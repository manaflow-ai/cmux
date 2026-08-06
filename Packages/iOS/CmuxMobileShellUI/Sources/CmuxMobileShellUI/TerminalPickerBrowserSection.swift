import CmuxMobileSupport
import SwiftUI

/// Mac-browser destinations shared by the toolbar menu and Labs switcher sheet.
struct TerminalPickerBrowserSection: View {
    let rows: [BrowserStreamPickerRow]
    let supportsBrowserStream: Bool
    let activeBrowserStreamPanelID: String?
    let selectBrowserStream: (String) -> Void

    var body: some View {
        if supportsBrowserStream {
            if !rows.isEmpty {
                Section(L10n.string("mobile.browserStream.menuTitle", defaultValue: "Mac Browsers")) {
                    ForEach(rows) { panel in
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
    }
}
