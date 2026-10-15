import CmuxSettings
import Foundation
import SwiftUI

/// The Browser Engine row in Settings > Browser: WebKit or Chromium for new
/// browser tabs (`browser.engine`).
///
/// Shown only when this build includes the Chromium runtime, or when the
/// setting already asks for Chromium (so it can be switched back). Existing
/// tabs keep their engine; the choice applies to tabs opened afterwards.
@MainActor
struct BrowserEngineSettingsRow: View {
    let controlWidth: CGFloat
    let isChromiumBundled: Bool

    @LiveSetting(\.browser.engine) private var engine

    var body: some View {
        if isChromiumBundled || engine == .chromium {
            SettingsCardRow(
                configurationReview: .json("browser.engine"),
                String(localized: "settings.browser.engine", defaultValue: "Browser Engine"),
                subtitle: subtitle,
                controlWidth: controlWidth
            ) {
                Picker("", selection: $engine) {
                    ForEach(BrowserEngineSetting.allCases, id: \.self) { engine in
                        Text(Self.displayName(engine)).tag(engine)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(String(localized: "settings.browser.engine", defaultValue: "Browser Engine"))
                .accessibilityIdentifier("SettingsBrowserEnginePicker")
            }
            SettingsCardDivider()
        }
    }

    private var subtitle: String {
        if isChromiumBundled {
            return String(
                localized: "settings.browser.engine.subtitle",
                defaultValue: "The engine new browser tabs open with. Open tabs keep theirs.",
                bundle: .module
            )
        }
        return String(
            localized: "settings.browser.engine.subtitleUnavailable",
            defaultValue: "This build doesn't include Chromium, so new browser tabs open in WebKit.",
            bundle: .module
        )
    }

    private static func displayName(_ engine: BrowserEngineSetting) -> String {
        switch engine {
        case .webkit:
            String(localized: "settings.browser.engine.webkit", defaultValue: "WebKit")
        case .chromium:
            String(localized: "settings.browser.engine.chromium", defaultValue: "Chromium")
        }
    }
}
