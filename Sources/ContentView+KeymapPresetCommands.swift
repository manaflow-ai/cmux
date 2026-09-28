import AppKit
import CmuxCommandPalette
import CmuxSettings
import CmuxSettingsUI

extension ContentView {
    /// Records that this install has been asked which base keymap it wants.
    ///
    /// Set when the chooser is answered, including by dismissing it, so a
    /// fresh install is asked exactly once.
    static let keymapChooserAnsweredDefaultsKey = "cmux.shortcuts.keymapChooser.answered.v1"

    /// Guards against two restored windows both opening the chooser.
    @MainActor
    private static var hasPresentedKeymapChooserThisLaunch = false

    /// Whether this window should open the first-run chooser as it appears.
    ///
    /// Claims the right to present as a side effect, so the first window to ask
    /// is the only one that shows it.
    @MainActor
    static func claimKeymapChooserPresentation() -> Bool {
        guard !hasPresentedKeymapChooserThisLaunch else { return false }
        guard keymapChooserLaunchDecision() == .open else { return false }
        hasPresentedKeymapChooserThisLaunch = true
        return true
    }

    /// Whether this launch should open the first-run base keymap chooser.
    ///
    /// The config file is created during store init, so "does cmux.json exist"
    /// cannot tell a new install from an old one by the time any view runs.
    /// ``KeyboardShortcutSettingsFileStore/primaryTemplateBootstrap`` captured
    /// the answer at the one moment it was knowable, and anything other than a
    /// file cmux itself created from the built-in template counts as history.
    @MainActor
    static func keymapChooserLaunchDecision(
        defaults: UserDefaults = .standard
    ) -> ShortcutKeymapChooserDecision {
        ShortcutKeymapChooserPolicy.decide(
            hasAnsweredChooser: defaults.bool(forKey: keymapChooserAnsweredDefaultsKey),
            installHasHistory: KeyboardShortcutSettings.settingsFileStore
                .primaryTemplateBootstrap != .createdFresh
        )
    }

    /// Marks the chooser answered so it never opens by itself again.
    @MainActor
    static func recordKeymapChooserAnswered(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: keymapChooserAnsweredDefaultsKey)
    }

    /// Writes the preset chosen in the first-run chooser.
    ///
    /// This plans against empty bindings rather than reading the file, which is
    /// correct only because the chooser opens solely when cmux just created the
    /// config file from the built-in template. That file carries no
    /// `shortcuts.bindings`, so there is nothing to preserve and nothing to
    /// race with. Settings plans against the live file instead.
    @MainActor
    static func applyKeymapChooserChoice(_ preset: ShortcutKeymapPreset) async {
        recordKeymapChooserAnswered()
        guard let runtime = AppDelegate.shared?.settingsRuntime else { return }
        let plan = preset.plan(
            from: ShortcutBindingsSnapshot(bindings: [:], managedActionIDs: []),
            defaultShortcutResolver: runtime.shortcutDefaultResolver
        )
        guard !plan.isEmpty else { return }
        do {
            try await runtime.jsonStore.applyShortcutKeymap(
                plan,
                bindingsID: runtime.catalog.shortcuts.bindings.id
            )
            runtime.hostActions.notifyShortcutSettingsDidChange()
        } catch {
            runtime.errorLog.record(error, keyID: runtime.catalog.shortcuts.bindings.id)
        }
    }

    static func keymapPresetCommandID(_ preset: ShortcutKeymapPreset) -> String {
        "palette.shortcutKeymap.\(preset.rawValue)"
    }

    /// The command that opens the chooser, the same one a fresh install sees.
    static let keymapChooserCommandID = "palette.shortcutKeymap.chooser"

    func appendKeymapPresetCommandContributions(to contributions: inout [CommandPaletteCommandContribution]) {
        let format = String(localized: "command.shortcutKeymap.title", defaultValue: "Base Keymap: %@")
        let subtitle = String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: Self.keymapChooserCommandID,
                title: { _ in
                    String(
                        localized: "command.shortcutKeymap.chooser.title",
                        defaultValue: "Choose Base Keymap…"
                    )
                },
                subtitle: { _ in subtitle },
                keywords: [
                    "keymap", "base", "keybindings", "shortcuts", "preset", "choose",
                    "compare", "style", "onboarding", "first run",
                ]
            )
        )
        for preset in ShortcutKeymapPreset.allCases {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: Self.keymapPresetCommandID(preset),
                    title: { _ in String.localizedStringWithFormat(format, preset.displayName) },
                    subtitle: { _ in subtitle },
                    keywords: [
                        "keymap", "base", "keybindings", "shortcuts", "preset", "default",
                        "iterm", "iterm2", "terminal", "tmux",
                        "browser", "chrome", "safari", "firefox", "tab",
                    ]
                )
            )
        }
    }

    /// Opens Settings > Keyboard Shortcuts with the preset's preview. Nothing
    /// is written until the user confirms there, the same path as the picker.
    func registerKeymapPresetCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.keymapChooserCommandID) {
            guard let appDelegate = AppDelegate.shared,
                  let runtime = appDelegate.settingsRuntime else {
                NSSound.beep()
                return
            }
            runtime.keymapProposals.isChooserRequested = true
            appDelegate.openPreferencesWindow(
                debugSource: Self.keymapChooserCommandID,
                navigationTarget: .keyboardShortcuts
            )
        }
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
