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

    /// Which window, if any, holds the right to present the first-run chooser.
    ///
    /// Ownership rather than a bare flag, because the release below has to
    /// tell the window that claimed apart from the windows that lost the race.
    /// With a bare flag, closing a window that never claimed freed the
    /// winner's claim, and the next window opened a second chooser on top of
    /// the first, with two selections racing the same write.
    struct KeymapChooserPresentationClaim {
        private(set) var owner: UUID?

        var isClaimed: Bool { owner != nil }

        /// Takes the claim for `windowId`, or reports that someone else holds it.
        mutating func claim(_ windowId: UUID) -> Bool {
            guard owner == nil else { return false }
            owner = windowId
            return true
        }

        /// Drops the claim only when `windowId` is the window that took it.
        @discardableResult
        mutating func release(_ windowId: UUID) -> Bool {
            guard owner == windowId else { return false }
            owner = nil
            return true
        }
    }

    /// Guards against two restored windows both opening the chooser.
    @MainActor
    private static var keymapChooserClaim = KeymapChooserPresentationClaim()

    /// Lets a UI test opt back into the chooser that tests otherwise suppress.
    ///
    /// Without this there is no way to drive the sheet from a test at all, and
    /// `scripts/ui-test` cannot capture a frame of it, since it runs XCUITests.
    /// Same shape as `MacSentryStartupPolicy`'s `CMUX_TEST_SENTRY_ENABLED`: the
    /// harness suppresses by default and one variable turns it back on.
    static let keymapChooserTestOptInEnvironmentKey = "CMUX_UI_TEST_KEYMAP_CHOOSER"

    /// Whether this window should open the first-run chooser as it appears.
    ///
    /// Claims the right to present as a side effect, so the first window to ask
    /// is the only one that shows it.
    @MainActor
    static func claimKeymapChooserPresentation(for windowId: UUID) -> Bool {
        guard !keymapChooserClaim.isClaimed else { return false }
        guard keymapChooserIsAllowedInThisProcess() else { return false }
        let decision = keymapChooserLaunchDecision()
        guard decision == .open else {
            // An install with history is answered for good, so a config file
            // that later goes missing cannot re-arm the sheet.
            if decision == .skipExistingInstall {
                recordKeymapChooserAnswered()
            }
            return false
        }
        return keymapChooserClaim.claim(windowId)
    }

    /// Gives another window a chance when the window that claimed the chooser
    /// goes away.
    ///
    /// Scoped to the owner, so a window that lost the race cannot free the
    /// winner's claim. Safe to call on every teardown: a chooser that was
    /// answered has written the answered marker, and the launch decision stops
    /// the next claim from reopening it.
    @MainActor
    static func releaseKeymapChooserPresentation(for windowId: UUID) {
        keymapChooserClaim.release(windowId)
    }

    /// Whether this process is allowed to open the chooser by itself.
    ///
    /// A modal sheet over the main window swallows the keystrokes a UI test
    /// sends, and whether it would appear is not something a test controls:
    /// four of the UI tests point HOME at a throwaway directory, which reads as
    /// a fresh install, while the rest run against the CI machine's own HOME,
    /// where a config file may or may not already exist. So the sheet would
    /// appear for some lanes and not others depending on machine state, which
    /// is worse than either answer. Suppressed by default, and a test that
    /// wants the sheet asks for it by name.
    ///
    /// Settings and the command palette do not go through here, so they reach
    /// the chooser under test either way.
    static func keymapChooserIsAllowedInThisProcess(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment[keymapChooserTestOptInEnvironmentKey] == "1" { return true }
        return !MacSentryStartupPolicy.isRunningUnderXCTest(environment: environment)
    }

    /// Whether this launch should open the first-run base keymap chooser.
    ///
    /// The config file is created during store init, so "does cmux.json exist"
    /// cannot tell a new install from an old one by the time any view runs.
    /// ``KeyboardShortcutSettingsFileStore/primaryTemplateBootstrap`` captured
    /// the answer at the one moment it was knowable, and anything other than a
    /// file cmux itself created from the built-in template counts as history.
    ///
    /// Shortcuts that older builds saved in UserDefaults count as history too.
    /// They outlive the config file, so a machine that has them has run cmux
    /// before even when cmux.json had to be created from the template.
    @MainActor
    static func keymapChooserLaunchDecision(
        defaults: UserDefaults = .standard
    ) -> ShortcutKeymapChooserDecision {
        let createdFresh = KeyboardShortcutSettings.settingsFileStore
            .primaryTemplateBootstrap == .createdFresh
        let hasLegacyBindings = !keymapChooserLegacyBindings().isEmpty
        return ShortcutKeymapChooserDecision(
            hasAnsweredChooser: defaults.bool(forKey: keymapChooserAnsweredDefaultsKey),
            installHasHistory: !createdFresh || hasLegacyBindings
        )
    }

    /// Shortcuts older Settings builds saved in UserDefaults, keyed by action id.
    ///
    /// The element type is spelled out because the app target has its own
    /// internal `StoredShortcut` in `KeyboardShortcutSettings.swift`, which
    /// shadows this one inside this module. Left unqualified, the two types
    /// meet at the `??` below and the compiler reports conflicting arguments
    /// to a generic parameter with the same type printed on both sides.
    @MainActor
    static func keymapChooserLegacyBindings() -> [String: CmuxSettings.StoredShortcut] {
        AppDelegate.shared?.settingsRuntime?.userDefaultsStore
            .initialLegacyShortcutBindings() ?? [:]
    }

    /// Marks the chooser answered so it never opens by itself again.
    @MainActor
    static func recordKeymapChooserAnswered(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: keymapChooserAnsweredDefaultsKey)
    }

    /// Applies a chooser plan and reports whether the chooser can dismiss.
    /// Empty plans are successful no-ops, while a failed write keeps the
    /// chooser open so the user can retry or choose Not Now.
    @MainActor
    static func applyKeymapChooserPlan(
        _ plan: ShortcutKeymapPlan,
        write: () async throws -> Void,
        onFailure: (Error) -> Void = { _ in }
    ) async -> Bool {
        guard !plan.isEmpty else { return true }
        do {
            try await write()
            return true
        } catch {
            onFailure(error)
            return false
        }
    }

    /// Writes the preset chosen in the first-run chooser.
    ///
    /// This plans against empty file bindings rather than reading the file,
    /// which is correct only because the chooser opens solely when cmux just
    /// created the config file from the built-in template. Every section of
    /// that template is commented out, so it carries no `shortcuts.bindings`
    /// and there is nothing in the file to preserve or race with. Legacy
    /// UserDefaults bindings are passed in, because those do outlive the file
    /// and a managed profile can force them onto a machine with no config yet.
    /// Settings plans against the live file instead.
    ///
    /// Does not record the answered marker itself. The sheet's `onDismiss`
    /// does that, and it runs on every way the sheet closes, including Not Now
    /// and Escape. Recording here as well would also mark a *failed* write as
    /// answered, so a user whose write failed and who quit rather than
    /// retrying would never be asked again.
    @MainActor
    static func applyKeymapChooserChoice(_ preset: ShortcutKeymapPreset) async -> Bool {
        guard let runtime = AppDelegate.shared?.settingsRuntime else { return false }
        let plan = preset.plan(
            from: ShortcutBindingsSnapshot(bindings: [:], managedActionIDs: []),
            legacyBindings: runtime.userDefaultsStore.initialLegacyShortcutBindings(),
            defaultShortcutResolver: runtime.shortcutDefaultResolver
        )
        let didApply = await applyKeymapChooserPlan(
            plan,
            write: {
                try await runtime.jsonStore.applyShortcutKeymap(
                    plan,
                    bindingsID: runtime.catalog.shortcuts.bindings.id
                )
            },
            onFailure: { error in
                runtime.errorLog.record(error, keyID: runtime.catalog.shortcuts.bindings.id)
            }
        )
        if didApply {
            runtime.hostActions.notifyShortcutSettingsDidChange()
        }
        return didApply
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
