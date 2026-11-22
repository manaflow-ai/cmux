/// `navigation.history.scope` in cmux.json (BACK-FORWARD-WORKSPACES-ONLY,
/// Lawrence: "app back/forth should only nav between workspaces by
/// default"): `workspaces` (default) makes a Back/Forward step only when the
/// selected workspace or top page changes; `everything` also steps through
/// tab, pane and page focus inside a workspace. A web page's own Back and
/// Forward stay the page's history. The app maps it to `HistoryStepScope`.
public nonisolated struct NavigationHistoryStepSetting {
    public nonisolated init() {}
    public static let configPath = ["navigation", "history", "scope"]
    public static let values = ["workspaces", "everything"]
    public static let fallback = "workspaces"

    static func parse(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, values.contains(text) else {
            let choices = values.map { "\"\($0)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "navigation.history.scope", message: "expected one of \(choices)"))
        }
        return (text, nil)
    }
}

extension CmuxConfigSnapshot {
    /// `navigation.historyScope` and `navigation.history.scope`.
    mutating func parseNavigationHistory(_ root: JSONValue) {
        let (scope, scopeDiagnostic) = NavigationHistoryScopeSetting.parse(root)
        navigationHistoryScope = scope
        if let scopeDiagnostic { diagnostics.append(scopeDiagnostic) }
        let (steps, stepsDiagnostic) = NavigationHistoryStepSetting.parse(root)
        navigationHistorySteps = steps
        if let stepsDiagnostic { diagnostics.append(stepsDiagnostic) }
    }
}
