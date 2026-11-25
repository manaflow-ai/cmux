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
/// Each key's path and default come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserPasswordsSetting: Sendable, Hashable {
    public var offerToSave = BrowserPasswordsSetting.offerToSaveDefault
    public var generate = BrowserPasswordsSetting.generateDefault
    public var allowExport = BrowserPasswordsSetting.allowExportDefault

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
        for descriptor in BrowserSettingsSchema.passwords {
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

extension BrowserPasswordsSetting {
    /// The values the app applies (the Passwords page's export gate and Chromium's policy): the
    /// effective root, so a managed value decides over the person's file, as Settings shows it.
    @MainActor public static func current(_ settings: SettingsController) -> BrowserPasswordsSetting {
        read(settings.snapshot.root)
    }
}
