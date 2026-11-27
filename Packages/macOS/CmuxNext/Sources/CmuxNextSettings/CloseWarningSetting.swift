/// `app.warnBeforeClosingTab` and `app.warnBeforeClosingAgentSession`, the
/// keys classic uses (#17430). Closing a tab or a workspace asks once while
/// a terminal runs a program; an agent at work in a terminal gets its own
/// question and its own toggle. Both are on when unset or invalid; the
/// question's "Don't ask again" turns its toggle off.
nonisolated extension CmuxConfigSnapshot {
    /// `app.warnBeforeClosingTab`.
    public var warnBeforeClosingTab: Bool { root.value(at: Self.warnBeforeClosingTabPath)?.boolValue ?? Self.warnBeforeClosingTabDefault }
    /// `app.warnBeforeClosingAgentSession`.
    public var warnBeforeClosingAgentSession: Bool { root.value(at: Self.warnBeforeClosingAgentSessionPath)?.boolValue ?? Self.warnBeforeClosingAgentSessionDefault }

    /// One diagnostic per close warning key set to something other than a bool.
    static func closeWarningDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        [warnBeforeClosingTabPath, warnBeforeClosingAgentSessionPath].compactMap { path in
            guard let value = root.value(at: path), value.boolValue == nil else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false")
        }
    }
}
