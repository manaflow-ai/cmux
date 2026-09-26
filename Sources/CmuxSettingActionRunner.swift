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
    @discardableResult
    static func run(
        _ change: CmuxSettingChange,
        actionSourcePath: String?,
        globalConfigPath: String,
        presentingWindow: NSWindow? = nil
    ) -> Bool {
        guard CmuxSettingActionTrust.allowsSettingAction(
            actionSourcePath: actionSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            NSSound.beep()
            return false
        }
        let store = store(for: globalConfigPath)
        Task { @MainActor [weak presentingWindow] in
            do {
                _ = try await store.apply(change)
            } catch {
                NSLog("[CmuxConfig] setting action on '%@' failed: %@", change.displayTarget, String(describing: error))
                presentFailure(error, window: presentingWindow)
            }
        }
        return true
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
        alert.informativeText = error.localizedDescription
        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
