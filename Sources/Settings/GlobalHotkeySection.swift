import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct GlobalHotkeySection: View {
    @AppStorage(SystemWideHotkeySettings.enabledKey) private var isEnabled = SystemWideHotkeySettings.defaultEnabled
    @State private var shortcut = KeyboardShortcutSettings.shortcut(for: SystemWideHotkeySettings.action)
    @State private var isManagedBySettingsFile = SystemWideHotkeySettings.isManagedBySettingsFile()

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                isEnabled = newValue
            }
        )
    }

    private var enableSubtitle: String {
        if isEnabled {
            return String(
                localized: "settings.globalHotkey.enable.subtitleOn",
                defaultValue: "Press the shortcut from any app to show or hide all cmux windows."
            )
        }
        return String(
            localized: "settings.globalHotkey.enable.subtitleOff",
            defaultValue: "Turn this on to show or hide all cmux windows from any app."
        )
    }

    var body: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey"))
            .accessibilityIdentifier("SettingsGlobalHotkeySection")
            .settingsSearchAnchor(SettingsSearchIndex.sectionID(for: .globalHotkey))

        SettingsCard {
            SettingsCardRow(
                configurationReview: .settingsOnly,
                String(localized: "settings.globalHotkey.enable", defaultValue: "Enable System-Wide Hotkey"),
                subtitle: enableSubtitle,
                searchAnchorID: SettingsSearchIndex.settingID(for: .globalHotkey, idSuffix: "enable-hotkey")
            ) {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityIdentifier("SettingsGlobalHotkeyToggle")
            }

            SettingsCardDivider()

            ShortcutRecorderSettingsControl(
                action: SystemWideHotkeySettings.action,
                shortcut: $shortcut,
                subtitle: isManagedBySettingsFile ? KeyboardShortcutSettings.settingsFileManagedSubtitle(for: SystemWideHotkeySettings.action) : nil,
                isDisabled: isManagedBySettingsFile
            )
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .accessibilityIdentifier("SettingsGlobalHotkeyRecorder")
                .settingsSearchAnchor(SettingsSearchIndex.settingID(for: .globalHotkey, idSuffix: "shortcut"))
        }
        .onChange(of: shortcut) { _, newValue in
            KeyboardShortcutSettings.setShortcut(newValue, for: SystemWideHotkeySettings.action)
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            syncFromDefaults()
        }

        SettingsCardNote(
            String(
                localized: "settings.globalHotkey.note",
                defaultValue: "Use Command, Option, or Control with another key. No extra macOS permission is required."
            )
        )
            .accessibilityIdentifier("SettingsGlobalHotkeyNote")
    }

    private func syncFromDefaults() {
        let latestShortcut = KeyboardShortcutSettings.shortcut(for: SystemWideHotkeySettings.action)
        let latestManagedState = SystemWideHotkeySettings.isManagedBySettingsFile()
        if latestShortcut != shortcut {
            shortcut = latestShortcut
        }
        if latestManagedState != isManagedBySettingsFile {
            isManagedBySettingsFile = latestManagedState
        }
    }
}
