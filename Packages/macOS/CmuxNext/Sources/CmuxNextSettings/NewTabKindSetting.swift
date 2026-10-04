/// What Cmd-T and the strip's + button open. A tab of the focused tab's
/// kind unless set (user decision 2026-10-01); the new tab page stays the
/// place to pick a kind explicitly.
public nonisolated enum NewTabDefaultKind: String, Sendable, Hashable, CaseIterable {
    /// The focused tab's kind: terminal, browser (on its engine) or agent.
    case sameKind = "same-kind"
    case terminal
    case browser
    case agent
    /// The new tab page, to pick the kind each time.
    case page
    /// The kind last opened in the focused tab's folder, else the kind last
    /// opened anywhere, else the focused tab's kind.
    case auto
}

/// `tabs.newTabKind` in cmux.json: "page" (default, the new tab screen,
/// plans/cmux-next/new-tab.md decision Q1), "same-kind", "terminal",
/// "browser", "agent" or "auto".
nonisolated extension NewTabDefaultKind {
    public static let configPath = ["tabs", "newTabKind"]
    public static let fallback: NewTabDefaultKind = .page

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (NewTabDefaultKind, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let kind = NewTabDefaultKind(rawValue: text) else {
            let choices = NewTabDefaultKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.newTabKind", message: "expected one of \(choices)"))
        }
        return (kind, nil)
    }
}
