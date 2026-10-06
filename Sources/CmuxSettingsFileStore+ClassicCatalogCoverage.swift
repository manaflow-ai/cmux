import CmuxSettings
import Foundation

/// Parsers for the classic settings that were catalogued before their
/// cmux.json representation was published.  Keeping these additions in an
/// extension leaves the long-lived section parser file easy to audit.
extension CmuxSettingsFileStore {
    func parseAccountSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let key = SettingCatalog().account.piiDisplayMode
        if let raw = jsonString(section["piiDisplayMode"]),
           let value = PIIDisplayMode(rawValue: raw) {
            snapshot.managedUserDefaults[key.userDefaultsKey] = .string(value.rawValue)
        } else if section.keys.contains("piiDisplayMode") {
            logInvalid(key.id, sourcePath: sourcePath)
        }
    }

    func parseDevicesSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let devices = SettingCatalog().devices
        for (jsonKey, key) in [
            ("discovery", devices.discoveryEnabled),
            ("incomingAccess", devices.incomingAccessEnabled),
        ] {
            guard section.keys.contains(jsonKey) else { continue }
            guard let nested = section[jsonKey] as? [String: Any] else {
                logInvalid("devices.\(jsonKey)", sourcePath: sourcePath)
                continue
            }
            if let value = jsonBool(nested["enabled"]) {
                snapshot.managedUserDefaults[key.userDefaultsKey] = .bool(value)
            } else if nested.keys.contains("enabled") {
                logInvalid("devices.\(jsonKey).enabled", sourcePath: sourcePath)
            }
        }

        guard section.keys.contains("sidebar") else { return }
        guard let sidebar = section["sidebar"] as? [String: Any] else {
            logInvalid("devices.sidebar", sourcePath: sourcePath)
            return
        }
        guard let rawIDs = classicJSONStringArray(sidebar["hiddenMacIDs"]) else {
            if sidebar.keys.contains("hiddenMacIDs") {
                logInvalid("devices.sidebar.hiddenMacIDs", sourcePath: sourcePath)
            }
            return
        }
        let ids = rawIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        snapshot.managedUserDefaults[devices.hiddenMacIDs.userDefaultsKey] = .stringArray(ids)
    }

    func parseClassicAppCatalogCoverage(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let app = SettingCatalog().app
        if let raw = jsonString(section["fileDropDefaultBehavior"]),
           let value = FileDropDefaultBehavior(rawValue: raw) {
            snapshot.managedUserDefaults[app.fileDropDefaultBehavior.userDefaultsKey] = .string(value.rawValue)
        } else if section.keys.contains("fileDropDefaultBehavior") {
            logInvalid(app.fileDropDefaultBehavior.id, sourcePath: sourcePath)
        }

        if let value = jsonInt(section["titlebarControlsStyle"]), TitlebarControlsStyle(rawValue: value) != nil {
            snapshot.managedUserDefaults[app.titlebarControlsStyle.userDefaultsKey] = .int(value)
        } else if section.keys.contains("titlebarControlsStyle") {
            logInvalid(app.titlebarControlsStyle.id, sourcePath: sourcePath)
        }

        if let raw = jsonString(section["workspaceButtonFade"]),
           WorkspaceButtonFadeSettings.Mode(rawValue: raw) != nil {
            snapshot.managedUserDefaults[app.workspaceButtonFade.userDefaultsKey] = .string(raw)
        } else if section.keys.contains("workspaceButtonFade") {
            logInvalid(app.workspaceButtonFade.id, sourcePath: sourcePath)
        }
        if let value = jsonBool(section["workspaceTitlebarVisibility"]) {
            snapshot.managedUserDefaults[app.workspaceTitlebarVisibility.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("workspaceTitlebarVisibility") {
            logInvalid(app.workspaceTitlebarVisibility.id, sourcePath: sourcePath)
        }
        if let value = jsonBool(section["systemWideHotkeyEnabled"]) {
            snapshot.managedUserDefaults[app.systemWideHotkeyEnabled.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("systemWideHotkeyEnabled") {
            logInvalid(app.systemWideHotkeyEnabled.id, sourcePath: sourcePath)
        }
    }

    func parseClassicBrowserCatalogCoverage(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let browser = SettingCatalog().browser
        if let value = jsonBool(section["disabled"]) {
            snapshot.managedUserDefaults[browser.disabled.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("disabled") {
            logInvalid(browser.disabled.id, sourcePath: sourcePath)
        }
        if let raw = jsonString(section["importHintVariant"]),
           BrowserImportHintVariant(rawValue: raw) != nil {
            snapshot.managedUserDefaults[browser.importHintVariant.userDefaultsKey] = .string(raw)
        } else if section.keys.contains("importHintVariant") {
            logInvalid(browser.importHintVariant.id, sourcePath: sourcePath)
        }
    }

    func parseClassicMobileCatalogCoverage(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let mobile = SettingCatalog().mobile
        if let value = jsonBool(section["phonePush.forwardingEnabled"]) {
            snapshot.managedUserDefaults[mobile.phonePushForwarding.userDefaultsKey] = .bool(value)
        }
        if let raw = jsonString(section["phonePush.mode"]), PhoneForwardingMode(rawValue: raw) != nil {
            snapshot.managedUserDefaults[mobile.phonePushMode.userDefaultsKey] = .string(raw)
        } else if section.keys.contains("phonePush.mode") {
            logInvalid(mobile.phonePushMode.id, sourcePath: sourcePath)
        }
        if let value = jsonBool(section["phonePush.hideContent"]) {
            snapshot.managedUserDefaults[mobile.phonePushHideContent.userDefaultsKey] = .bool(value)
        }

        if let rawPhonePush = section["phonePush"] as? [String: Any] {
            if let value = jsonBool(rawPhonePush["forwardingEnabled"]) {
                snapshot.managedUserDefaults[mobile.phonePushForwarding.userDefaultsKey] = .bool(value)
            } else if rawPhonePush.keys.contains("forwardingEnabled") {
                logInvalid(mobile.phonePushForwarding.id, sourcePath: sourcePath)
            }
            if let raw = jsonString(rawPhonePush["mode"]), PhoneForwardingMode(rawValue: raw) != nil {
                snapshot.managedUserDefaults[mobile.phonePushMode.userDefaultsKey] = .string(raw)
            } else if rawPhonePush.keys.contains("mode") {
                logInvalid(mobile.phonePushMode.id, sourcePath: sourcePath)
            }
            if let value = jsonBool(rawPhonePush["hideContent"]) {
                snapshot.managedUserDefaults[mobile.phonePushHideContent.userDefaultsKey] = .bool(value)
            } else if rawPhonePush.keys.contains("hideContent") {
                logInvalid(mobile.phonePushHideContent.id, sourcePath: sourcePath)
            }
        } else if section.keys.contains("phonePush") {
            logInvalid("mobile.phonePush", sourcePath: sourcePath)
        }

        guard let rawPairing = section["iOSPairingHost"] as? [String: Any] else {
            if section.keys.contains("iOSPairingHost") { logInvalid("mobile.iOSPairingHost", sourcePath: sourcePath) }
            return
        }
        if let value = jsonBool(rawPairing["enabled"]) {
            snapshot.managedUserDefaults[mobile.iOSPairingHost.userDefaultsKey] = .bool(value)
        } else if rawPairing.keys.contains("enabled") {
            logInvalid(mobile.iOSPairingHost.id, sourcePath: sourcePath)
        }
        if let value = jsonInt(rawPairing["port"]), (1...65_535).contains(value) {
            snapshot.managedUserDefaults[mobile.iOSPairingPort.userDefaultsKey] = .int(value)
        } else if rawPairing.keys.contains("port") {
            logInvalid(mobile.iOSPairingPort.id, sourcePath: sourcePath)
        }
        if let raw = jsonString(rawPairing["displayName"]) {
            snapshot.managedUserDefaults[mobile.iOSPairingDisplayName.userDefaultsKey] = .string(raw)
        } else if rawPairing.keys.contains("displayName") {
            logInvalid(mobile.iOSPairingDisplayName.id, sourcePath: sourcePath)
        }
    }

    func parseClassicSidebarAppearanceCatalogCoverage(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let appearance = SettingCatalog().sidebarAppearance
        if let value = jsonDouble(section["blurOpacity"]), value.isFinite, (0...1).contains(value) {
            snapshot.managedUserDefaults[appearance.blurOpacity.userDefaultsKey] = .double(value)
        } else if section.keys.contains("blurOpacity") {
            logInvalid(appearance.blurOpacity.id, sourcePath: sourcePath)
        }
        if let value = jsonDouble(section["cornerRadius"]), value.isFinite, (0...20).contains(value) {
            snapshot.managedUserDefaults[appearance.cornerRadius.userDefaultsKey] = .double(value)
        } else if section.keys.contains("cornerRadius") {
            logInvalid(appearance.cornerRadius.id, sourcePath: sourcePath)
        }
        let presetValues = Set(CmuxSettings.SidebarPresetOption.allCases.map(\.rawValue))
            .union(SidebarPresetOption.allCases.map(\.rawValue))
        let materialValues = Set(CmuxSettings.SidebarMaterialOption.allCases.map(\.rawValue))
            .union(SidebarMaterialOption.allCases.map(\.rawValue))
        let stateValues = Set(CmuxSettings.SidebarStateOption.allCases.map(\.rawValue))
            .union(SidebarStateOption.allCases.map(\.rawValue))
        if let raw = jsonString(section["preset"]), presetValues.contains(raw) {
            snapshot.managedUserDefaults[appearance.preset.userDefaultsKey] = .string(raw)
        } else if section.keys.contains("preset") {
            logInvalid(appearance.preset.id, sourcePath: sourcePath)
        }
        if let raw = jsonString(section["material"]), materialValues.contains(raw) {
            snapshot.managedUserDefaults[appearance.material.userDefaultsKey] = .string(raw)
        } else if section.keys.contains("material") {
            logInvalid(appearance.material.id, sourcePath: sourcePath)
        }
        if let raw = jsonString(section["blendMode"]),
           Set(CmuxSettings.SidebarBlendModeOption.allCases.map(\.rawValue))
               .union(SidebarBlendModeOption.allCases.map(\.rawValue))
               .contains(raw) {
            snapshot.managedUserDefaults[appearance.blendMode.userDefaultsKey] = .string(raw)
        } else if section.keys.contains("blendMode") {
            logInvalid(appearance.blendMode.id, sourcePath: sourcePath)
        }
        if let raw = jsonString(section["state"]), stateValues.contains(raw) {
            snapshot.managedUserDefaults[appearance.state.userDefaultsKey] = .string(raw)
        } else if section.keys.contains("state") {
            logInvalid(appearance.state.id, sourcePath: sourcePath)
        }
    }

    func parseClassicWorkspaceGroupsCatalogCoverage(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let key = SettingCatalog().workspaceGroups.anchorCloseSuppressed
        if let value = jsonBool(section["anchorCloseSuppressed"]) {
            snapshot.managedUserDefaults[key.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("anchorCloseSuppressed") {
            logInvalid(key.id, sourcePath: sourcePath)
        }
    }

    private func classicJSONStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [Any] else { return nil }
        return values.compactMap { $0 as? String }.count == values.count
            ? values.compactMap { $0 as? String }
            : nil
    }
}
