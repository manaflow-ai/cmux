import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

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

nonisolated enum BuildFlavor: String, Sendable {
    case dev
    case nightly
    case stable

    static var current: BuildFlavor {
        let bundle = Bundle.main
        return detect(
            bundleNames: [
                bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                ProcessInfo.processInfo.processName,
            ].compactMap { $0 },
            bundleIdentifier: bundle.bundleIdentifier
        )
    }

    static func detect(bundleName: String?, bundleIdentifier: String?) -> BuildFlavor {
        detect(bundleNames: [bundleName].compactMap { $0 }, bundleIdentifier: bundleIdentifier)
    }

    static func detect(bundleNames: [String], bundleIdentifier: String?) -> BuildFlavor {
        if bundleNames.contains(where: containsDevToken) {
            return .dev
        }

        let normalizedBundleIdentifier = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if SocketControlSettings.isDebugLikeBundleIdentifier(normalizedBundleIdentifier) {
            return .dev
        }
        if normalizedBundleIdentifier == "com.cmuxterm.app.nightly"
            || normalizedBundleIdentifier?.hasPrefix("com.cmuxterm.app.nightly.") == true {
            return .nightly
        }
        if bundleNames.contains(where: containsNightlyToken) {
            return .nightly
        }
        return .stable
    }

    private static func containsDevToken(_ name: String) -> Bool {
        containsToken("DEV", in: name)
    }

    private static func containsNightlyToken(_ name: String) -> Bool {
        containsToken("NIGHTLY", in: name)
    }

    private static func containsToken(_ token: String, in name: String) -> Bool {
        name
            .uppercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains { String($0) == token }
    }
}
