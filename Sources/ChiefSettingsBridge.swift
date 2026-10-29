import AppKit
import CmuxSettings
import Foundation

/// Synchronous read/write access to the `chief.*` settings for Chief UI.
///
/// Reads and writes go through the settings catalog's ``DefaultsKey`` direct
/// accessors, the same key, type and encoding the Settings window's
/// `UserDefaultsSettingsStore` uses. The store observes
/// `UserDefaults.didChangeNotification`, so a write here updates an open
/// Settings window and every `@LiveSetting(\.chief.…)` view without extra
/// plumbing. Values set in `cmux.json` are imported into the same keys when
/// the file loads or changes.
///
/// ```swift
/// if ChiefSettings.isEnabled {
///     launch(harness: ChiefSettings.harness, model: ChiefSettings.model)
/// }
/// ChiefSettings.setHarness(.codex)
/// ```
///
/// SwiftUI views that need to re-render on change should read
/// `@LiveSetting(\.chief.harness)` (etc.) instead of these accessors.
enum ChiefSettings {
    private static let keys = ChiefCatalogSection()

    /// `chief.enabled`: whether the Home row and Chief entry points are shown.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        keys.enabled.value(in: defaults)
    }

    /// `chief.harness`, falling back to ``ChiefHarnessSetting/defaultHarness`` for an
    /// unknown stored value.
    static func harness(in defaults: UserDefaults) -> ChiefHarnessSetting {
        ChiefHarnessSetting(rawValue: keys.harness.value(in: defaults)) ?? .defaultHarness
    }

    /// `chief.model`, or `nil` when empty (use the harness default).
    static func model(in defaults: UserDefaults) -> String? {
        nonEmpty(keys.model.value(in: defaults))
    }

    /// `chief.effort`, or `nil` when empty (use the harness default).
    static func effort(in defaults: UserDefaults) -> String? {
        nonEmpty(keys.effort.value(in: defaults))
    }

    /// `chief.dangerouslySkipPermissions`: whether new turns may bypass agent permission prompts.
    static func dangerouslySkipPermissions(in defaults: UserDefaults) -> Bool {
        keys.dangerouslySkipPermissions.value(in: defaults)
    }

    static var isEnabled: Bool { isEnabled(in: .standard) }
    static var harness: ChiefHarnessSetting { harness(in: .standard) }
    static var model: String? { model(in: .standard) }
    static var effort: String? { effort(in: .standard) }
    static var dangerouslySkipPermissions: Bool { dangerouslySkipPermissions(in: .standard) }

    /// Persists `chief.enabled`.
    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        keys.enabled.set(enabled, in: defaults)
    }

    /// Persists `chief.harness`.
    static func setHarness(_ harness: ChiefHarnessSetting, in defaults: UserDefaults = .standard) {
        keys.harness.set(harness.rawValue, in: defaults)
    }

    /// Persists `chief.model`; `nil` or blank restores the harness default.
    static func setModel(_ model: String?, in defaults: UserDefaults = .standard) {
        keys.model.set(nonEmpty(model) ?? "", in: defaults)
    }

    /// Persists `chief.effort`; `nil` or blank restores the harness default.
    static func setEffort(_ effort: String?, in defaults: UserDefaults = .standard) {
        keys.effort.set(nonEmpty(effort) ?? "", in: defaults)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension AppDelegate {
    /// The one Open Chief path shared by the keyboard shortcut, the View menu
    /// item and the command palette.
    ///
    /// Posts ``Notification/Name/cmuxOpenChiefHome`` (or, with `toggle`,
    /// ``Notification/Name/cmuxToggleChiefHome``) with `preferredWindow`
    /// (a main window) as the object, or no object to target the active main
    /// window, and `["source": source]` as user info. The shortcut and the
    /// View menu item (which shows the same keys) toggle, so the keys that
    /// opened Home return to the workspace; the palette's "Open Chief" opens.
    /// Returns `false` without posting when `chief.enabled` is off, so a
    /// disabled shortcut falls through to the focused surface.
    @discardableResult
    func openChiefHome(preferredWindow: NSWindow? = nil, toggle: Bool = false, source: String) -> Bool {
        guard ChiefSettings.isEnabled else { return false }
        NotificationCenter.default.post(
            name: toggle ? .cmuxToggleChiefHome : .cmuxOpenChiefHome,
            object: preferredWindow,
            userInfo: ["source": source]
        )
        return true
    }
}
