import AppKit
import CmuxCommandPalette
import CmuxSettings
import CmuxSettingsUI

extension ContentView {
    private static var keymapPresetTitleFormat: String {
        String(localized: "command.shortcutKeymap.title", defaultValue: "Base Keymap: %@")
    }

    static func keymapPresetCommandID(_ preset: ShortcutKeymapPreset) -> String {
        "palette.shortcutKeymap.\(preset.rawValue)"
    }

    func appendKeymapPresetCommandContributions(to contributions: inout [CommandPaletteCommandContribution]) {
        let format = Self.keymapPresetTitleFormat
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

    func registerKeymapPresetCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        for preset in ShortcutKeymapPreset.allCases {
            registry.register(commandId: Self.keymapPresetCommandID(preset)) {
                Task { @MainActor in await Self.applyKeymapPreset(preset) }
            }
        }
    }

    /// Applies `preset` through the same plan and store path as the Settings
    /// picker, then reports what changed.
    @MainActor
    private static func applyKeymapPreset(_ preset: ShortcutKeymapPreset) async {
        guard let runtime = AppDelegate.shared?.settingsRuntime else {
            NSSound.beep()
            return
        }
        let bindingsKey = runtime.catalog.shortcuts.bindingSnapshot
        let plan = preset.plan(
            from: await runtime.jsonStore.value(for: bindingsKey),
            defaultShortcutResolver: runtime.shortcutDefaultResolver
        )
        let alert = NSAlert()
        do {
            try await runtime.jsonStore.applyShortcutKeymap(plan, bindingsID: bindingsKey.id)
            runtime.hostActions.notifyShortcutSettingsDidChange()
            alert.messageText = String.localizedStringWithFormat(keymapPresetTitleFormat, preset.displayName)
            alert.informativeText = ShortcutKeymapPlanText.lines(for: plan).joined(separator: "\n")
            alert.alertStyle = plan.systemConflicts.isEmpty ? .informational : .warning
        } catch {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "dialog.shortcutKeymap.failed.title", defaultValue: "Keymap Not Changed")
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        _ = alert.runCmuxModal()
    }
}
