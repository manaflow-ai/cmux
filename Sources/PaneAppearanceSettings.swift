import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation

enum PaneAppearanceSettings {
    private static let app = AppCatalogSection()

    static var paneBorderColorKey: String { app.paneBorderColorHex.userDefaultsKey }
    static var activePaneBorderColorKey: String { app.activePaneBorderColorHex.userDefaultsKey }
    static var notificationRingColorKey: String { app.notificationRingColorHex.userDefaultsKey }
    static var unfocusedPaneOpacityKey: String { app.unfocusedPaneOpacity.userDefaultsKey }

    static func paneBorderColorHex(defaults: UserDefaults = .standard) -> String? {
        normalizedHex(defaults.string(forKey: paneBorderColorKey))
    }

    static func paneBorderColor(defaults: UserDefaults = .standard) -> NSColor? {
        paneBorderColorHex(defaults: defaults).flatMap(NSColor.init(hex:))
    }

    static func activePaneBorderColor(defaults: UserDefaults = .standard) -> NSColor? {
        normalizedHex(defaults.string(forKey: activePaneBorderColorKey)).flatMap(NSColor.init(hex:))
    }

    static func notificationRingColor(defaults: UserDefaults = .standard) -> NSColor? {
        normalizedHex(defaults.string(forKey: notificationRingColorKey)).flatMap(NSColor.init(hex:))
    }

    static func unfocusedPaneOpacityOverride(defaults: UserDefaults = .standard) -> Double? {
        guard let number = defaults.object(forKey: unfocusedPaneOpacityKey) as? NSNumber else { return nil }
        return min(max(number.doubleValue, 0), 1)
    }

    static func signature(defaults: UserDefaults = .standard) -> String {
        let opacity = unfocusedPaneOpacityOverride(defaults: defaults)
            .map { String(format: "%.4f", $0) } ?? "nil"
        return [
            paneBorderColorHex(defaults: defaults) ?? "nil",
            activePaneBorderColor(defaults: defaults)?.hexString(includeAlpha: true) ?? "nil",
            notificationRingColor(defaults: defaults)?.hexString(includeAlpha: true) ?? "nil",
            opacity,
        ].joined(separator: "|")
    }

    static func notifyDidChange(notificationCenter: NotificationCenter = .default) {
        notificationCenter.post(name: .ghosttyConfigDidReload, object: nil)
    }

    private static func normalizedHex(_ raw: String?) -> String? {
        guard let raw,
              let normalized = WorkspaceTabColorSettings.normalizedHex(raw),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}

extension CmuxSettingsFileStore {
    func parsePaneAppearanceSettings(
        from section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) -> Bool {
        let app = AppCatalogSection()
        var stagedDefaults: [(String, ManagedSettingsValue)] = []

        if section.keys.contains("paneBorderColor") {
            guard let value = parseNullableHex(
                section["paneBorderColor"],
                path: "app.paneBorderColor",
                sourcePath: sourcePath
            ) else { return false }
            stagedDefaults.append((app.paneBorderColorHex.userDefaultsKey, .nullableString(value)))
        }
        if section.keys.contains("activePaneBorderColor") {
            guard let value = parseNullableHex(
                section["activePaneBorderColor"],
                path: "app.activePaneBorderColor",
                sourcePath: sourcePath
            ) else { return false }
            stagedDefaults.append((app.activePaneBorderColorHex.userDefaultsKey, .nullableString(value)))
        }
        if section.keys.contains("notificationRingColor") {
            guard let value = parseNullableHex(
                section["notificationRingColor"],
                path: "app.notificationRingColor",
                sourcePath: sourcePath
            ) else { return false }
            stagedDefaults.append((app.notificationRingColorHex.userDefaultsKey, .nullableString(value)))
        }
        if let value = jsonDouble(section["unfocusedPaneOpacity"]) {
            guard value >= 0, value <= 1 else {
                logInvalid("app.unfocusedPaneOpacity", sourcePath: sourcePath)
                return false
            }
            stagedDefaults.append((app.unfocusedPaneOpacity.userDefaultsKey, .double(value)))
        } else if section.keys.contains("unfocusedPaneOpacity") {
            logInvalid("app.unfocusedPaneOpacity", sourcePath: sourcePath)
            return false
        }

        for (key, value) in stagedDefaults {
            snapshot.managedUserDefaults[key] = value
        }

        return true
    }
}
