import AppKit
import CmuxSidebarInterpreterClient
import CmuxSidebarRemoteRender
import CmuxSocketControl
import CmuxSettings
import CmuxSettingsUI
import CmuxUpdaterUI
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers


// MARK: - Quit Confirmation Settings
enum QuitWarningSettings {
    static let warnBeforeQuitKey = "warnBeforeQuitShortcut"
    static let confirmQuitKey = "confirmQuit"
    static let defaultWarnBeforeQuit = true
    static let defaultConfirmQuitMode = QuitConfirmationMode.always

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        confirmQuitMode(defaults: defaults) != .never
    }

    static func shouldShowConfirmation(
        isQuitWarningConfirmed: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        shouldShowConfirmation(
            isQuitWarningConfirmed: isQuitWarningConfirmed,
            hasDirtyWorkspaces: true,
            buildFlavor: .current,
            defaults: defaults
        )
    }

    static func shouldShowConfirmation(
        isQuitWarningConfirmed: Bool,
        hasDirtyWorkspaces: Bool,
        buildFlavor: BuildFlavor,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !isQuitWarningConfirmed else { return false }
        guard buildFlavor != .dev else { return false }

        switch confirmQuitMode(defaults: defaults) {
        case .always:
            return true
        case .dirtyOnly:
            return hasDirtyWorkspaces
        case .never:
            return false
        }
    }

    static func confirmQuitMode(defaults: UserDefaults = .standard) -> QuitConfirmationMode {
        if let rawValue = defaults.string(forKey: confirmQuitKey),
           let mode = QuitConfirmationMode(rawValue: rawValue) {
            return mode
        }
        if defaults.object(forKey: warnBeforeQuitKey) == nil {
            return defaultConfirmQuitMode
        }
        return defaults.bool(forKey: warnBeforeQuitKey) ? .always : .never
    }

    static func setMode(_ mode: QuitConfirmationMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: confirmQuitKey)
        defaults.set(mode != .never, forKey: warnBeforeQuitKey)
    }

    static func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        setMode(isEnabled ? .always : .never, defaults: defaults)
    }
}

nonisolated enum QuitConfirmationMode: String, CaseIterable, Sendable {
    case always
    case dirtyOnly = "dirty-only"
    case never

    var localizedSettingsTitle: String {
        switch self {
        case .always:
            return String(localized: "settings.app.confirmQuit.always", defaultValue: "Always")
        case .dirtyOnly:
            return String(localized: "settings.app.confirmQuit.dirtyOnly", defaultValue: "Dirty Only")
        case .never:
            return String(localized: "settings.app.confirmQuit.never", defaultValue: "Never")
        }
    }
}

