import CmuxSettings
import Foundation
import SwiftUI

/// The Terminal Link Placement picker in Settings > Browser, followed by its divider.
@MainActor
struct BrowserTerminalLinkPlacementSettingRow: View {
    let controlWidth: CGFloat

    @LiveSetting(\.browser.terminalLinkBrowserPlacement) private var placement

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("browser.terminalLinkBrowserPlacement"),
            String(localized: "settings.browser.terminalLinkBrowserPlacement", defaultValue: "Terminal Link Placement"),
            subtitle: String(localized: "settings.browser.terminalLinkBrowserPlacement.subtitle", defaultValue: "Where terminal links and intercepted `open` commands open in the cmux browser. Split uses the pane to the right or makes a new split. Tab in Same Pane adds a tab next to the terminal."),
            controlWidth: controlWidth
        ) {
            Picker("", selection: $placement) {
                ForEach(TerminalLinkBrowserPlacement.allCases, id: \.self) { placement in
                    Text(Self.displayName(placement)).tag(placement)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(String(localized: "settings.browser.terminalLinkBrowserPlacement", defaultValue: "Terminal Link Placement"))
            .accessibilityIdentifier("SettingsBrowserTerminalLinkPlacementPicker")
        }
        SettingsCardDivider()
    }

    private static func displayName(_ placement: TerminalLinkBrowserPlacement) -> String {
        switch placement {
        case .split:
            String(localized: "settings.browser.terminalLinkBrowserPlacement.split", defaultValue: "Split")
        case .samePane:
            String(localized: "settings.browser.terminalLinkBrowserPlacement.samePane", defaultValue: "Tab in Same Pane")
        }
    }
}
