import Foundation
import SwiftUI

/// The Chrome Extensions row in Settings > Browser (design spec §10): where
/// extensions live and a Manage button that opens `chrome://extensions` in a
/// Chromium tab.
///
/// Shown only when this build includes the Chromium runtime; extensions are
/// a Chromium-engine feature.
@MainActor
struct BrowserExtensionsSettingsRow: View {
    let controlWidth: CGFloat
    let isChromiumBundled: Bool
    let onManage: () -> Void

    var body: some View {
        if isChromiumBundled {
            SettingsCardRow(
                String(localized: "settings.browser.extensions", defaultValue: "Chrome Extensions"),
                subtitle: String(
                    localized: "settings.browser.extensions.subtitle",
                    defaultValue: "Chromium tabs run Chrome extensions. Install them from the Chrome Web Store and pin them from the Extensions button in the toolbar."
                ),
                controlWidth: controlWidth
            ) {
                Button(String(localized: "settings.browser.extensions.manage", defaultValue: "Manage…"), action: onManage)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "settings.browser.extensions.manageLabel", defaultValue: "Manage Chrome Extensions"))
                    .accessibilityIdentifier("SettingsBrowserExtensionsManageButton")
            }
            SettingsCardDivider()
        }
    }
}
