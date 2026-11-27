/// `browser.builtInAdBlocker` in cmux.json: the full uBlock Origin (Manifest
/// V2, GPL-3.0) that ships inside cmux loads into Chromium tabs. On by
/// default; off, Chromium starts without it the next time it starts (the
/// extension and its settings stay in the profile).
///
/// `configPath` and `fallback` come from schemas/settings/source/browser.json (SettingsSchema+Browser.generated.swift).
public nonisolated struct BuiltInAdBlockerSetting: Sendable {
    public init() {}
}
