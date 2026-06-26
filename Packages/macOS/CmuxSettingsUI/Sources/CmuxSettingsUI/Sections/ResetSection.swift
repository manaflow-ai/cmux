import CmuxFoundation
import CmuxSettings
import SwiftUI

/// **Reset** section — mirrors the legacy in-app section: a single
/// centered "Reset All Settings" button wrapped in a `SettingsCard`.
/// Matches legacy behavior: the action fires immediately on click,
/// without a confirmation dialog.
@MainActor
public struct ResetSection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let jsonStore: JSONConfigStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, jsonStore: JSONConfigStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.jsonStore = jsonStore
        self.catalog = catalog
    }

    public var body: some View {
        Group {
            SettingsSectionHeader(String(localized: "settings.section.reset", defaultValue: "Reset"), section: .reset)
            SettingsCard {
                HStack {
                    Spacer(minLength: 0)
                    Button(String(localized: "settings.reset.resetAll", defaultValue: "Reset All Settings")) {
                        Task { await resetAll() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .settingsSearchAnchors(["setting:reset:reset-all"])
        }
    }

    private func resetAll() async {
        await defaultsStore.resetAll(catalog.all)
        for key in catalog.all {
            await key.resetInJSON(jsonStore)
        }
        NotificationCenter.default.post(name: GlobalFontMagnification.didChangeNotification, object: nil)
    }
}
