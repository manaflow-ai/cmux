/// What Quit does with the local terminals, which run in cmux-tui and
/// outlive the app (user decisions 2026-09-30).
public nonisolated enum QuitBehavior: String, Sendable, Hashable, CaseIterable {
    /// Quit and leave the terminals running.
    case keep
    /// Quit, end every local terminal and stop the local cmux-tui daemon;
    /// workspaces and splits stay and reopen with fresh shells.
    case endKeepLayout = "end-keep-layout"
    /// As `endKeepLayout` from the quit action; Cmd-Q with this set ends the
    /// sessions but keeps the workspaces (`QuitRules.decide`).
    case endEverything = "end-everything"
}

/// `app.quitBehavior` in cmux.json: "keep" (default), "end-keep-layout"
/// or "end-everything". Two older values read as their successors and are
/// rewritten once (`migrateLegacyQuitBehavior`): "end" (the first
/// release's) as "end-keep-layout", and "ask" (the removed "Quit cmux?"
/// alert, Leo 2026-11-05) is removed, so it reads as the default.
public nonisolated enum QuitBehaviorSetting {
    /// The value "end-keep-layout" replaced.
    public static let legacyEnd = "end"
    /// The value that showed the quit alert; "keep" replaced it.
    public static let legacyAsk = "ask"

    static func legacy(_ text: String?) -> QuitBehavior? {
        switch text {
        case legacyEnd: .endKeepLayout
        case legacyAsk: .keep
        default: nil
        }
    }

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (QuitBehavior, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        if let behavior = legacy(value.stringValue) { return (behavior, nil) }
        guard let text = value.stringValue, let behavior = QuitBehavior(rawValue: text) else {
            let choices = QuitBehavior.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "app.quitBehavior", message: "expected one of \(choices)"))
        }
        return (behavior, nil)
    }
}

extension SettingsController {
    /// Rewrites a legacy `app.quitBehavior` so the Settings window shows
    /// it: "end" as "end-keep-layout", and "ask" removed (the default).
    /// Returns whether it wrote.
    @discardableResult
    public func migrateLegacyQuitBehavior() async throws -> Bool {
        switch try await file.value(at: QuitBehaviorSetting.configPath)?.stringValue {
        case QuitBehaviorSetting.legacyEnd:
            try await file.set(.string(QuitBehavior.endKeepLayout.rawValue), at: QuitBehaviorSetting.configPath)
        case QuitBehaviorSetting.legacyAsk:
            try await file.remove(QuitBehaviorSetting.configPath)
        default:
            return false
        }
        return true
    }
}
