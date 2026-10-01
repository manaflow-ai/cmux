import CmuxSettings
import SwiftUI

/// Immutable row inputs keep observation in the owning Browser section.
@MainActor
struct BrowserTerminalLinkSettingsRows: View {
    let openLinks: Bool
    let interceptOpen: Bool
    let placement: TerminalLinkBrowserPlacement
    let setOpenLinks: (Bool) -> Void
    let setInterceptOpen: (Bool) -> Void
    let setPlacement: (TerminalLinkBrowserPlacement) -> Void

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("browser.openTerminalLinksInCmuxBrowser"),
            String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"),
            subtitle: String(localized: "settings.browser.openTerminalLinks.subtitle", defaultValue: "When off, links clicked in terminal output open in your default browser.")
        ) {
            Toggle("", isOn: Binding(get: { openLinks }, set: setOpenLinks))
                .labelsHidden()
                .controlSize(.small)
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("browser.interceptTerminalOpenCommandInCmuxBrowser"),
            String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"),
            subtitle: String(localized: "settings.browser.interceptOpen.subtitle", defaultValue: "When off, `open https://...` and `open http://...` always use your default browser.")
        ) {
            Toggle("", isOn: Binding(get: { interceptOpen }, set: setInterceptOpen))
                .labelsHidden()
                .controlSize(.small)
        }
        SettingsCardDivider()
        SettingsCardRow(
            configurationReview: .json("browser.terminalLinkBrowserPlacement"),
            String(localized: "settings.browser.terminalLinkPlacement", defaultValue: "Terminal Link Placement"),
            subtitle: String(localized: "settings.browser.terminalLinkPlacement.subtitle", defaultValue: "Where clicked terminal links and intercepted open commands create browser tabs. Manual browser splits are unchanged."),
            controlWidth: 196
        ) {
            Picker("", selection: Binding(get: { placement }, set: setPlacement)) {
                Text(String(localized: "settings.browser.terminalLinkPlacement.split", defaultValue: "Split Right"))
                    .tag(TerminalLinkBrowserPlacement.split)
                Text(String(localized: "settings.browser.terminalLinkPlacement.samePane", defaultValue: "Tab in Same Pane"))
                    .tag(TerminalLinkBrowserPlacement.samePane)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsTerminalLinkBrowserPlacementPicker")
        }
    }
}
