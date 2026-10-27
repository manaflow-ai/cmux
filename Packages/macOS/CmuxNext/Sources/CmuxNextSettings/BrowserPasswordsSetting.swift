import CmuxNextDesignTokens

/// The browser password manager's keys in cmux.json (plans/cmux-next/passwords.md 1.1, 1.3, 1.4):
///
/// ```jsonc
/// "browser": { "passwords": { "offerToSave": true, "generate": true, "allowExport": false } }
/// ```
///
/// `offerToSave`: a Chromium tab asks to save a sign-in the person submits (the tab's prompt bar).
/// `generate`: Chromium suggests a strong password for a new-password field. `allowExport`: the
/// Passwords page may write every saved password to a plain-text CSV, after a native confirmation and
/// device owner authentication; off by default (decision P3). The app reads them from the effective
/// root (``current(_:)``), so the snapshot type does not grow; a bad value is the default plus a diagnostic.
public nonisolated struct BrowserPasswordsSetting: Sendable, Hashable {
    public static let offerToSavePath = ["browser", "passwords", "offerToSave"]
    public static let generatePath = ["browser", "passwords", "generate"]
    public static let allowExportPath = ["browser", "passwords", "allowExport"]

    public var offerToSave = true
    public var generate = true
    public var allowExport = false

    public init() {}

    public static let fallback = BrowserPasswordsSetting()

    /// The values in cmux.json's root; a missing or bad value is its default.
    public static func read(_ root: JSONValue) -> BrowserPasswordsSetting {
        var diagnostics: [SettingsDiagnostic] = []
        return parse(root, diagnostics: &diagnostics)
    }

    /// Checked against its schema rows, so the parser and the Settings window agree.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BrowserPasswordsSetting {
        var setting = fallback
        for descriptor in BrowserPasswordsSettingsSchema.descriptors {
            guard let value = root.value(at: descriptor.path) else { continue }
            guard descriptor.accepts(value), let flag = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            switch descriptor.path {
            case offerToSavePath: setting.offerToSave = flag
            case generatePath: setting.generate = flag
            case allowExportPath: setting.allowExport = flag
            default: break
            }
        }
        return setting
    }
}

/// The password manager's rows (Browser > Passwords).
nonisolated enum BrowserPasswordsSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.passwords", "Passwords")
        typealias S = BrowserPasswordsSetting
        return [
            SettingDescriptor(
                S.offerToSavePath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.passwords.offerToSave", "Offer to Save Passwords"),
                help: SettingsText.keyed("settings.browser.passwords.offerToSave.help",
                                         "A browser tab asks to save a sign-in you submit. Tabs an agent drives never ask."),
                kind: .toggle, default: .bool(S.fallback.offerToSave), keywords: ["password", "save", "sign in", "login", "credentials"]
            ),
            SettingDescriptor(
                S.generatePath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.passwords.generate", "Suggest Strong Passwords"),
                help: SettingsText.keyed("settings.browser.passwords.generate.help",
                                         "Offers a generated password when a site asks for a new one, and saves it."),
                kind: .toggle, default: .bool(S.fallback.generate), keywords: ["password", "generate", "strong", "suggest"]
            ),
            SettingDescriptor(
                S.allowExportPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.passwords.allowExport", "Allow Password Export"),
                help: SettingsText.keyed("settings.browser.passwords.allowExport.help",
                                         "Lets the Passwords page write every saved password to a plain-text CSV file, after you confirm with Touch ID or your password."),
                kind: .toggle, default: .bool(S.fallback.allowExport), keywords: ["password", "export", "csv", "backup"]
            ),
        ]
    }

    /// The person decides what the password manager saves, suggests and writes out (decision P2:
    /// agents see no sites or usernames, and change none of this).
    static var refusedKeys: [String: SettingsSchema.AgentRefusal] {
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, .privacy) })
    }
}

extension BrowserPasswordsSetting {
    /// The values the app applies (the Passwords page's export gate and Chromium's policy): the
    /// effective root, so a managed value decides over the person's file, as Settings shows it.
    @MainActor public static func current(_ settings: SettingsController) -> BrowserPasswordsSetting {
        read(settings.snapshot.root)
    }
}
