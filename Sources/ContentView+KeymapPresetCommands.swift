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
                    keywords: Self.keymapPresetKeywords(preset)
                )
            )
        }
    }

    /// Search terms for one preset's palette entry.
    ///
    /// Per preset, not shared: one list for the whole loop meant typing "chrome"
    /// surfaced the tmux entry and typing "tmux" surfaced the browser one.
    static func keymapPresetKeywords(_ preset: ShortcutKeymapPreset) -> [String] {
        let shared = ["keymap", "base", "keybindings", "shortcuts", "preset", "default"]
        switch preset {
        case .cmux:
            return shared + ["cmux", "built in", "builtin", "stock", "reset"]
        case .iTerm2:
            return shared + ["iterm", "iterm2"]
        case .terminal:
            return shared + ["terminal", "terminal.app", "apple"]
        case .tmux:
            return shared + ["tmux", "prefix", "ctrl-b", "multiplexer", "screen"]
        case .browser:
            return shared + ["browser", "chrome", "safari", "firefox", "arc", "tab", "ctrl-tab"]
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
