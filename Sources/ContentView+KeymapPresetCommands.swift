import AppKit
import CmuxCommandPalette
import CmuxSettings
import CmuxSettingsUI

extension ContentView {
    static func keymapPresetCommandID(_ preset: ShortcutKeymapPreset) -> String {
        "palette.shortcutKeymap.\(preset.rawValue)"
    }

    func appendKeymapPresetCommandContributions(to contributions: inout [CommandPaletteCommandContribution]) {
        let format = String(localized: "command.shortcutKeymap.title", defaultValue: "Base Keymap: %@")
        let subtitle = String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        for preset in ShortcutKeymapPreset.allCases {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: Self.keymapPresetCommandID(preset),
                    title: { _ in String.localizedStringWithFormat(format, preset.displayName) },
                    subtitle: { _ in subtitle },
                    keywords: ["keymap", "base", "keybindings", "shortcuts", "preset", "iterm", "iterm2", "terminal", "tmux", "default"]
                )
            )
        }
    }

    /// Opens Settings > Keyboard Shortcuts with the preset's preview. Nothing
    /// is written until the user confirms there, the same path as the picker.
    func registerKeymapPresetCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        for preset in ShortcutKeymapPreset.allCases {
            registry.register(commandId: Self.keymapPresetCommandID(preset)) {
                guard let appDelegate = AppDelegate.shared,
                      let runtime = appDelegate.settingsRuntime else {
                    NSSound.beep()
                    return
                }
                runtime.keymapProposals.preset = preset
                appDelegate.openPreferencesWindow(
                    debugSource: Self.keymapPresetCommandID(preset),
                    navigationTarget: .keyboardShortcuts
                )
            }
        }
    }
}
