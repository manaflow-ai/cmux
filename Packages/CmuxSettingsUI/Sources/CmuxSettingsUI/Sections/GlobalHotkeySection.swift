import CmuxSettings
import SwiftUI

/// **Global Hotkey** section — mirrors the legacy in-app section:
/// one card with an Enable toggle and a chord recorder, followed by
/// a card note.
@MainActor
public struct GlobalHotkeySection: View {
    private let defaultsStore: UserDefaultsSettingsStore
    private let catalog: SettingCatalog

    public init(defaultsStore: UserDefaultsSettingsStore, catalog: SettingCatalog) {
        self.defaultsStore = defaultsStore
        self.catalog = catalog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsSectionHeader(String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey"))
                .accessibilityIdentifier("SettingsGlobalHotkeySection")
            mainCard
            SettingsCardNote(
                String(localized: "settings.globalHotkey.note", defaultValue: "Use Command, Option, or Control with another key. No extra macOS permission is required.")
            )
            .accessibilityIdentifier("SettingsGlobalHotkeyNote")
        }
    }

    @ViewBuilder
    private var mainCard: some View {
        let enabled = DefaultsValueModel(store: defaultsStore, key: catalog.app.systemWideHotkeyEnabled)
        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey"),
                subtitle: enabled.current
                    ? String(localized: "settings.globalHotkey.enable.subtitleOn", defaultValue: "The configured chord toggles cmux visibility from any application.")
                    : String(localized: "settings.globalHotkey.enable.subtitleOff", defaultValue: "The chord below is recorded but inactive until you enable it here.")
            ) {
                Toggle("", isOn: Binding(get: { enabled.current }, set: { enabled.set($0) }))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGlobalHotkeyToggle")
            }
            SettingsCardDivider()
            recorderRow
        }
    }

    @ViewBuilder
    private var recorderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "settings.globalHotkey.recorder.label", defaultValue: "Hotkey"))
                .font(.system(size: 13, weight: .medium))
            ShortcutRecorderView(placeholder: String(localized: "settings.globalHotkey.recorder.placeholder", defaultValue: "Click and press a shortcut")) { _ in
                // The chord is configured in Keyboard Shortcuts → Toggle cmux;
                // this recorder is wired as a convenience but routes through
                // the same JSON-backed shortcuts dictionary.
            }
            .frame(width: 200, height: 26)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityIdentifier("SettingsGlobalHotkeyRecorder")
    }
}
