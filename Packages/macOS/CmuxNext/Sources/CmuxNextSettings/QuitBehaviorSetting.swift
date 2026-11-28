/// What Quit does with the local terminals, which run in cmux-tui and
/// outlive the app (user decisions 2026-09-30).
public nonisolated enum QuitBehavior: String, Sendable, Hashable, CaseIterable {
    /// Show the quit sheet when local terminals exist.
    case ask
    /// Quit and leave the terminals running.
    case keep
    /// Quit, end every local terminal and stop the local cmux-tui daemon;
    /// workspaces and splits stay and reopen with fresh shells.
    case endKeepLayout = "end-keep-layout"
    /// As `endKeepLayout`, and also delete every local workspace, so the
    /// next launch opens one new workspace.
    case endEverything = "end-everything"
}

/// `app.quitBehavior` in cmux.json: "ask" (default), "keep",
/// "end-keep-layout" or "end-everything". The quit sheet's "Don't ask
/// again" writes the chosen one. "end" (the first release's value) reads
/// as "end-keep-layout" and is rewritten once (`migrateLegacyQuitBehavior`).
public nonisolated enum QuitBehaviorSetting {
    public static let configPath = ["app", "quitBehavior"]
    public static let fallback: QuitBehavior = .ask
    /// The value "end-keep-layout" replaced.
    public static let legacyEnd = "end"

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (QuitBehavior, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        if value.stringValue == legacyEnd { return (.endKeepLayout, nil) }
        guard let text = value.stringValue, let behavior = QuitBehavior(rawValue: text) else {
            let choices = QuitBehavior.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "app.quitBehavior", message: "expected one of \(choices)"))
        }
        return (behavior, nil)
    }
}

extension SettingsController {
    /// Rewrites `app.quitBehavior: "end"` as "end-keep-layout" so the
    /// Settings window shows it. Returns whether it wrote.
    @discardableResult
    public func migrateLegacyQuitBehavior() async throws -> Bool {
        guard try await file.value(at: QuitBehaviorSetting.configPath)?.stringValue == QuitBehaviorSetting.legacyEnd else { return false }
        try await file.set(.string(QuitBehavior.endKeepLayout.rawValue), at: QuitBehaviorSetting.configPath)
        return true
    }
}
