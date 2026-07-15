import CmuxCore
import SwiftUI

/// The browser-engine policy row in Browser settings.
@MainActor
struct BrowserEngineSettingRow: View {
    let model: DefaultsValueModel<BrowserEnginePreference>
    let controlWidth: CGFloat

    var body: some View {
        SettingsCardRow(
            configurationReview: .json("browser.engine"),
            String(localized: "settings.browser.engine", defaultValue: "Browser Engine"),
            subtitle: String(
                localized: "settings.browser.engine.subtitle",
                defaultValue: "Auto follows your macOS default browser for new tabs. Remote-proxied panes and cmux pages use WebKit."
            ),
            controlWidth: controlWidth
        ) {
            Picker("", selection: selection) {
                ForEach(BrowserEnginePreference.allCases, id: \.self) { preference in
                    Text(label(for: preference)).tag(preference)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("SettingsBrowserEnginePicker")
        }
    }

    private var selection: Binding<BrowserEnginePreference> {
        Binding(get: { model.current }, set: { model.set($0) })
    }

    private func label(for preference: BrowserEnginePreference) -> String {
        switch preference {
        case .automatic:
            return String(localized: "settings.browser.engine.auto", defaultValue: "Auto")
        case .webKit:
            return String(localized: "settings.browser.engine.webKit", defaultValue: "Safari (WebKit)")
        case .chromium:
            return String(localized: "settings.browser.engine.chromium", defaultValue: "Chromium")
        }
    }
}
