/// Email verification AutoFill in cmux.json (plans/cmux-next/email-verification-autofill/DESIGN.md):
///
/// ```jsonc
/// "browser": { "verificationAutofill": { "enabled": false } }
/// ```
///
/// `enabled`: when a site's page waits for a verification email, the tab's prompt bar offers the
/// code or link from that site's email. Off by default: it reads mail the person opted into. The
/// app reads it from the effective root (``current(_:)``), so the snapshot type does not grow; a
/// bad value is the default plus a diagnostic. Agents can neither read offers nor change it.
///
/// The key's path and default come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BrowserVerificationAutofillSetting: Sendable, Hashable {
    /// Whether the browser offers codes and links from verification emails.
    public var enabled = BrowserVerificationAutofillSetting.enabledDefault

    public init() {}

    /// The value with nothing configured: off.
    public static let fallback = BrowserVerificationAutofillSetting()

    /// The value in cmux.json's root; a missing or bad value is the default.
    /// - Parameter root: The effective cmux.json root.
    /// - Returns: The setting.
    public static func read(_ root: JSONValue) -> BrowserVerificationAutofillSetting {
        var diagnostics: [SettingsDiagnostic] = []
        return parse(root, diagnostics: &diagnostics)
    }

    /// Checked against its schema row, so the parser and the Settings window agree.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> BrowserVerificationAutofillSetting {
        var setting = fallback
        for descriptor in BrowserSettingsSchema.verificationAutofill {
            guard let value = root.value(at: descriptor.path) else { continue }
            guard descriptor.accepts(value), let flag = value.boolValue else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: descriptor.id, message: OmnibarSettingsSchema.expectation(descriptor)))
                continue
            }
            if descriptor.path == enabledPath { setting.enabled = flag }
        }
        return setting
    }
}

extension BrowserVerificationAutofillSetting {
    /// The value the app applies: the effective root, so a managed value decides over the person's file.
    /// - Parameter settings: The settings controller.
    /// - Returns: The setting.
    @MainActor public static func current(_ settings: SettingsController) -> BrowserVerificationAutofillSetting {
        read(settings.snapshot.root)
    }
}
