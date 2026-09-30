import AppKit
import CmuxSettings
import Foundation

/// Which config files may declare `"type": "setting"` actions.
enum CmuxSettingActionTrust {
    /// Setting actions rewrite the global cmux.json, so they only run when the
    /// user's global config, or a pack it references, declared them. A
    /// missing source fails closed.
    static func allowsSettingAction(actionSourcePath: String?, globalConfigPath: String) -> Bool {
        guard let actionSourcePath else { return false }
        return standardized(actionSourcePath) == standardized(globalConfigPath)
    }

    private static func standardized(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}

/// Runs `"type": "setting"` and `"type": "settingPreset"` actions from the
/// command palette, shortcuts, and surface tab bar buttons.
///
/// The edit goes through ``JSONConfigStore/apply(_:)``, the same path
/// `cmux config set|toggle|cycle|preset` uses, and the config file watcher
/// applies the result like any other cmux.json edit.
@MainActor
enum CmuxSettingActionRunner {
    private static var stores: [String: JSONConfigStore] = [:]

    /// Starts the change and returns whether it was accepted to run. A
    /// refused or failed write shows an alert with the reason.
    ///
    /// With `confirm`, the action's `"confirm": true`, the change waits for
    /// the user to accept a dialog showing the equivalent `cmux config`
    /// command. Setting actions only come from the global config, which the
    /// project-action trust prompt never covers, so this is the only prompt
    /// they get.
    @discardableResult
    static func run(
        _ change: CmuxSettingChange,
        actionSourcePath: String?,
        globalConfigPath: String,
        settingPresets: [String: CmuxSettingValue] = [:],
        confirm: Bool = false,
        title: String? = nil,
        presentingWindow: NSWindow? = nil
    ) -> Bool {
        guard CmuxSettingActionTrust.allowsSettingAction(
            actionSourcePath: actionSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            NSSound.beep()
            return false
        }
        guard confirm else {
            apply(
                change,
                globalConfigPath: globalConfigPath,
                settingPresets: settingPresets,
                presentingWindow: presentingWindow
            )
            return true
        }
        let alert = confirmationAlert(for: change, title: title)
        if let window = presentingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { [weak window] response in
                guard response == .alertFirstButtonReturn else { return }
                apply(
                    change,
                    globalConfigPath: globalConfigPath,
                    settingPresets: settingPresets,
                    presentingWindow: window
                )
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            apply(
                change,
                globalConfigPath: globalConfigPath,
                settingPresets: settingPresets,
                presentingWindow: nil
            )
        }
        return true
    }

    static func confirmationAlert(for change: CmuxSettingChange, title: String?) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.messageText = (trimmedTitle?.isEmpty == false)
            ? trimmedTitle!
            : String(localized: "settingAction.confirm.title", defaultValue: "Change Setting?")
        alert.informativeText = String(
            format: String(
                localized: "settingAction.confirm.message",
                defaultValue: "This action edits your cmux.json:\n\n%@"
            ),
            change.commandLineDescription
        )
        alert.addButton(withTitle: String(localized: "settingAction.confirm.apply", defaultValue: "Change"))
        alert.addButton(withTitle: String(localized: "dialog.cmuxConfig.confirmCommand.cancel", defaultValue: "Cancel"))
        return alert
    }

    private static func apply(
        _ change: CmuxSettingChange,
        globalConfigPath: String,
        settingPresets: [String: CmuxSettingValue],
        presentingWindow: NSWindow?
    ) {
        let store = store(for: globalConfigPath)
        Task { @MainActor [weak presentingWindow] in
            do {
                // Start toggle and cycle from what the user sees: a value set
                // in the Settings window lives in UserDefaults, not cmux.json.
                _ = try await store.apply(
                    change,
                    liveValues: .userDefaults(suiteName: nil),
                    presetOverrides: settingPresets
                )
            } catch {
                NSLog("[CmuxConfig] setting action on '%@' failed: %@", change.displayTarget, String(describing: error))
                presentFailure(error, window: presentingWindow)
            }
        }
    }

    private static func store(for globalConfigPath: String) -> JSONConfigStore {
        if let existing = stores[globalConfigPath] {
            return existing
        }
        let store = JSONConfigStore(fileURL: URL(fileURLWithPath: globalConfigPath))
        stores[globalConfigPath] = store
        return store
    }

    private static func presentFailure(_ error: any Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "settingAction.failed.title",
            defaultValue: "Couldn't Change Setting"
        )
        alert.informativeText = (error as? LocalizedError)?.errorDescription
            ?? String(
                localized: "settingAction.failed.unreadable",
                defaultValue: "cmux couldn't read or save ~/.config/cmux/cmux.json. Check it for a syntax error, then try again."
            )
        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
