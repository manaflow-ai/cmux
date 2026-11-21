import CmuxFoundation
import Foundation

/// Settings-file parsers for the window's look: the sidebar tint
/// (`sidebarAppearance`) and the window background image (`windowBackground`).
/// Extracted from `KeyboardShortcutSettingsFileStore.swift`, which sits at its
/// file-length budget.
extension CmuxSettingsFileStore {
    /// Parses the `sidebarAppearance` and `windowBackground` sections.
    func parseAppearanceSections(
        _ root: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let sidebarAppearanceSection = root["sidebarAppearance"] as? [String: Any] {
            parseSidebarAppearanceSection(sidebarAppearanceSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let windowBackgroundSection = root["windowBackground"] as? [String: Any] {
            parseWindowBackgroundSection(windowBackgroundSection, sourcePath: sourcePath, snapshot: &snapshot)
        } else if root.keys.contains("windowBackground") {
            logInvalid("windowBackground", sourcePath: sourcePath)
        }
    }

    /// Parses `windowBackground`. Each key is validated on its own, so a bad
    /// `imageFit` does not drop a good `image`.
    private func parseWindowBackgroundSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if section.keys.contains("image") {
            if section["image"] is NSNull {
                snapshot.managedUserDefaults[WindowBackgroundImageSettings.pathDefaultsKey] = .string("")
            } else if let raw = jsonString(section["image"]) {
                let settings = WindowBackgroundImageSettings(path: raw)
                let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                if !settings.isEnabled || settings.resolvedFileURL(homeDirectory: homeDirectory) != nil {
                    snapshot.managedUserDefaults[WindowBackgroundImageSettings.pathDefaultsKey] = .string(settings.path)
                } else {
                    logInvalid("windowBackground.image", sourcePath: sourcePath)
                }
            } else {
                logInvalid("windowBackground.image", sourcePath: sourcePath)
            }
        }
        if section.keys.contains("imageOpacity") {
            if let value = jsonDouble(section["imageOpacity"]), value.isFinite {
                snapshot.managedUserDefaults[WindowBackgroundImageSettings.opacityDefaultsKey] = .double(
                    WindowBackgroundImageSettings(path: "", opacity: value).opacity
                )
            } else {
                logInvalid("windowBackground.imageOpacity", sourcePath: sourcePath)
            }
        }
        if section.keys.contains("imageFit") {
            if let raw = jsonString(section["imageFit"]), WindowBackgroundImageFit(rawValue: raw) != nil {
                snapshot.managedUserDefaults[WindowBackgroundImageSettings.fitDefaultsKey] = .string(raw)
            } else {
                logInvalid("windowBackground.imageFit", sourcePath: sourcePath)
            }
        }
    }
}
