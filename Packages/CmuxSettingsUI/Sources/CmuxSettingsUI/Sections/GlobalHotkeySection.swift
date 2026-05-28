import CmuxSettings
import SwiftUI

/// SwiftUI view for the **Global Hotkey** section.
///
/// The global hotkey is the system-wide keyboard shortcut that toggles
/// cmux visibility from any application. It depends on AppKit's
/// `NSEvent.addGlobalMonitorForEvents` and the `cmux` app's first-class
/// hotkey controller (`Sources/HotKeyController.swift` etc.) — none of
/// which are part of the settings *storage* refactor.
///
/// This section will host:
///
/// 1. A `Toggle` for "Enable system-wide hotkey".
/// 2. A keyboard-recorder control that captures the chord and writes it
///    to a catalog entry (TODO: `GlobalHotkeyCatalogSection`).
///
/// Today both controls live in `Sources/cmuxApp.swift`'s `SettingsView`
/// and bind to `@AppStorage`-backed values that haven't been moved into
/// the catalog yet.
public struct GlobalHotkeySection: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Global Hotkey", systemImage: "keyboard.badge.ellipsis")
                .font(.title2)
                .padding(.top)
            Text("System-wide hotkey configuration is not yet part of the settings-storage catalog. The recorder + enable toggle live in `Sources/cmuxApp.swift` SettingsView's global-hotkey rows and bind directly to `@AppStorage`.")
                .foregroundStyle(.secondary)
            Text("Migration target: introduce `GlobalHotkeyCatalogSection` with an `enable: DefaultsKey<Bool>` and a `binding: DefaultsKey<KeyboardShortcut>` (new SettingCodable value type), then rebuild this view with `SettingsToggleRow` + a `SettingsShortcutRecorderRow`.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
