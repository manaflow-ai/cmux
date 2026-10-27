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
public nonisolated struct BrowserVerificationAutofillSetting: Sendable, Hashable {
    /// The key path of the switch.
    public static let enabledPath = ["browser", "verificationAutofill", "enabled"]

    /// Whether the browser offers codes and links from verification emails.
    public var enabled = false

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
        for descriptor in BrowserVerificationAutofillSettingsSchema.descriptors {
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

/// Email verification AutoFill's row (Browser > Passwords), shown in Settings and the palette. Off
/// by default; the person turns it on.
nonisolated enum BrowserVerificationAutofillSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.passwords", "Passwords")
        return [
            SettingDescriptor(
                BrowserVerificationAutofillSetting.enabledPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.verificationAutofill.enabled", "Fill Codes from Verification Emails"),
                help: SettingsText.keyed("settings.browser.verificationAutofill.enabled.help",
                                         "When a site emails you a code or link, its tab offers it. Only on the sender's own site, never filled without your click, and never stored."),
                kind: .toggle, default: .bool(BrowserVerificationAutofillSetting.fallback.enabled),
                keywords: ["email", "verification", "code", "one-time", "otp", "2fa", "autofill", "magic link"]
            ),
        ]
    }

    /// The person decides whether cmux reads verification emails (privacy: agents never change it).
    static var refusedKeys: [String: SettingsSchema.AgentRefusal] {
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, .privacy) })
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
