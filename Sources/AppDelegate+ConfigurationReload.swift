import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Configuration reload menu and Ghostty config observation
extension AppDelegate {
    func installGhosttyConfigObserver() {
        guard ghosttyConfigObserver == nil else { return }
        ghosttyConfigObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshGhosttyGotoSplitShortcuts()
        }
    }

    @objc func reloadConfigurationMenuItem(_ sender: Any?) {
        reloadConfiguration(source: "menu.reload_configuration")
    }

    func installReloadConfigurationMenuItemAction() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        appMenu.delegate = self
        configureReloadConfigurationMenuItem(in: appMenu)
    }

    func scheduleReloadConfigurationMenuItemRefresh() {
        guard !reloadConfigurationMenuItemRefreshScheduled else { return }
        reloadConfigurationMenuItemRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadConfigurationMenuItemRefreshScheduled = false
            self.installReloadConfigurationMenuItemAction()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === NSApp.mainMenu?.items.first?.submenu else { return }
        configureReloadConfigurationMenuItem(in: menu)
    }

    private func configureReloadConfigurationMenuItem(in menu: NSMenu) {
        guard let item = reloadConfigurationMenuItem(in: menu) else { return }

        item.identifier = Self.reloadConfigurationMenuItemIdentifier
        item.target = self
        item.action = #selector(reloadConfigurationMenuItem(_:))

        let shortcut = KeyboardShortcutSettings.menuShortcut(for: .reloadConfiguration)
        if let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    private func reloadConfigurationMenuItem(in menu: NSMenu) -> NSMenuItem? {
        if let identifiedItem = menu.items.first(where: { $0.identifier == Self.reloadConfigurationMenuItemIdentifier }) {
            return identifiedItem
        }

        let reloadConfigurationTitle = String(
            localized: "menu.app.reloadConfiguration",
            defaultValue: "Reload Configuration"
        )
        return menu.items.first(where: { $0.title == reloadConfigurationTitle })
    }

    func reloadConfiguration(
        soft: Bool = false,
        source: String,
        reloadSettingsFromFile: Bool = true,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference? = nil
    ) {
#if DEBUG
        cmuxDebugLog("reload.config.request source=\(source) soft=\(soft)")
#endif
        GhosttyApp.shared.reloadConfiguration(
            soft: soft,
            source: source,
            reloadSettingsFromFile: reloadSettingsFromFile,
            preferredColorScheme: preferredColorScheme
        )
    }

    func reloadCmuxConfigStores(source: String) {
        var seenStores = Set<ObjectIdentifier>()
        for context in mainWindowContexts.values {
            guard let store = context.cmuxConfigStore else { continue }
            let identifier = ObjectIdentifier(store)
            guard seenStores.insert(identifier).inserted else { continue }
            store.loadAll()
        }
#if DEBUG
        cmuxDebugLog("cmuxConfig.reload source=\(source) stores=\(seenStores.count)")
#endif
    }

    func refreshGhosttyGotoSplitShortcuts() {
        guard let config = GhosttyApp.shared.config else {
            ghosttyGotoSplitLeftShortcut = nil
            ghosttyGotoSplitRightShortcut = nil
            ghosttyGotoSplitUpShortcut = nil
            ghosttyGotoSplitDownShortcut = nil
            return
        }

        ghosttyGotoSplitLeftShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:left", UInt("goto_split:left".utf8.count))
        )
        ghosttyGotoSplitRightShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:right", UInt("goto_split:right".utf8.count))
        )
        ghosttyGotoSplitUpShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:up", UInt("goto_split:up".utf8.count))
        )
        ghosttyGotoSplitDownShortcut = storedShortcutFromGhosttyTrigger(
            ghostty_config_trigger(config, "goto_split:down", UInt("goto_split:down".utf8.count))
        )
    }

    private func storedShortcutFromGhosttyTrigger(_ trigger: ghostty_input_trigger_s) -> StoredShortcut? {
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_PHYSICAL:
            switch trigger.key.physical {
            case GHOSTTY_KEY_ARROW_LEFT:
                key = "←"
            case GHOSTTY_KEY_ARROW_RIGHT:
                key = "→"
            case GHOSTTY_KEY_ARROW_UP:
                key = "↑"
            case GHOSTTY_KEY_ARROW_DOWN:
                key = "↓"
            case GHOSTTY_KEY_A: key = "a"
            case GHOSTTY_KEY_B: key = "b"
            case GHOSTTY_KEY_C: key = "c"
            case GHOSTTY_KEY_D: key = "d"
            case GHOSTTY_KEY_E: key = "e"
            case GHOSTTY_KEY_F: key = "f"
            case GHOSTTY_KEY_G: key = "g"
            case GHOSTTY_KEY_H: key = "h"
            case GHOSTTY_KEY_I: key = "i"
            case GHOSTTY_KEY_J: key = "j"
            case GHOSTTY_KEY_K: key = "k"
            case GHOSTTY_KEY_L: key = "l"
            case GHOSTTY_KEY_M: key = "m"
            case GHOSTTY_KEY_N: key = "n"
            case GHOSTTY_KEY_O: key = "o"
            case GHOSTTY_KEY_P: key = "p"
            case GHOSTTY_KEY_Q: key = "q"
            case GHOSTTY_KEY_R: key = "r"
            case GHOSTTY_KEY_S: key = "s"
            case GHOSTTY_KEY_T: key = "t"
            case GHOSTTY_KEY_U: key = "u"
            case GHOSTTY_KEY_V: key = "v"
            case GHOSTTY_KEY_W: key = "w"
            case GHOSTTY_KEY_X: key = "x"
            case GHOSTTY_KEY_Y: key = "y"
            case GHOSTTY_KEY_Z: key = "z"
            case GHOSTTY_KEY_DIGIT_0: key = "0"
            case GHOSTTY_KEY_DIGIT_1: key = "1"
            case GHOSTTY_KEY_DIGIT_2: key = "2"
            case GHOSTTY_KEY_DIGIT_3: key = "3"
            case GHOSTTY_KEY_DIGIT_4: key = "4"
            case GHOSTTY_KEY_DIGIT_5: key = "5"
            case GHOSTTY_KEY_DIGIT_6: key = "6"
            case GHOSTTY_KEY_DIGIT_7: key = "7"
            case GHOSTTY_KEY_DIGIT_8: key = "8"
            case GHOSTTY_KEY_DIGIT_9: key = "9"
            case GHOSTTY_KEY_BRACKET_LEFT: key = "["
            case GHOSTTY_KEY_BRACKET_RIGHT: key = "]"
            case GHOSTTY_KEY_MINUS: key = "-"
            case GHOSTTY_KEY_EQUAL: key = "="
            case GHOSTTY_KEY_COMMA: key = ","
            case GHOSTTY_KEY_PERIOD: key = "."
            case GHOSTTY_KEY_SLASH: key = "/"
            case GHOSTTY_KEY_SEMICOLON: key = ";"
            case GHOSTTY_KEY_QUOTE: key = "'"
            case GHOSTTY_KEY_BACKQUOTE: key = "`"
            case GHOSTTY_KEY_BACKSLASH: key = "\\"
            default:
                return nil
            }
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = UnicodeScalar(trigger.key.unicode) else { return nil }
            key = String(Character(scalar)).lowercased()
        case GHOSTTY_TRIGGER_CATCH_ALL:
            return nil
        default:
            return nil
        }

        let mods = trigger.mods.rawValue
        let command = (mods & GHOSTTY_MODS_SUPER.rawValue) != 0
        let shift = (mods & GHOSTTY_MODS_SHIFT.rawValue) != 0
        let option = (mods & GHOSTTY_MODS_ALT.rawValue) != 0
        let control = (mods & GHOSTTY_MODS_CTRL.rawValue) != 0

        // Ignore bogus empty triggers.
        if key.isEmpty || (!command && !shift && !option && !control) {
            return nil
        }

        return StoredShortcut(key: key, command: command, shift: shift, option: option, control: control)
    }

    @objc func handleThemesReloadNotification(_ notification: Notification) {
        let targetBundleIdentifier =
            notification.userInfo?["bundleIdentifier"] as? String
            ?? notification.object as? String
        if let targetBundleIdentifier,
           let bundleIdentifier = Bundle.main.bundleIdentifier,
           !targetBundleIdentifier.isEmpty,
           targetBundleIdentifier != bundleIdentifier {
            return
        }

        let source = GhosttySurfaceConfigurationRefresh.cmuxThemeReloadSource(
            phase: notification.userInfo?["phase"] as? String
        )
        DispatchQueue.main.async {
            self.reloadGhosttyConfigurationForCmuxThemeSource(source)
        }
    }

    func reloadGhosttyConfigurationForCmuxThemeSource(_ source: String) {
        if GhosttySurfaceConfigurationRefresh.shouldDebounceCmuxThemeReload(source: source) {
            cmuxThemePreviewReloadGeneration += 1
            let generation = cmuxThemePreviewReloadGeneration
            cmuxThemePreviewReloadWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.cmuxThemePreviewReloadGeneration == generation else { return }
                self.cmuxThemePreviewReloadWorkItem = nil
                self.reloadConfiguration(source: source)
            }
            cmuxThemePreviewReloadWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(
                    GhosttySurfaceConfigurationRefresh.cmuxThemePreviewReloadDebounceMilliseconds
                ),
                execute: workItem
            )
            return
        }

        cmuxThemePreviewReloadGeneration += 1
        cmuxThemePreviewReloadWorkItem?.cancel()
        cmuxThemePreviewReloadWorkItem = nil
        reloadConfiguration(source: source)
    }
}
