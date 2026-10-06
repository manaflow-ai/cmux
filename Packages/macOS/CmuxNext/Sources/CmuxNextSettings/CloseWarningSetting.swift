/// `app.warnBeforeClosingTab` and `app.warnBeforeClosingAgentSession`, the
/// keys classic uses (#17430). Closing a tab or a workspace asks once while
/// a terminal runs a program; an agent at work in a terminal gets its own
/// question and its own toggle. Both are on when unset or invalid; the
/// question's "Don't ask again" turns its toggle off.
nonisolated extension CmuxConfigSnapshot {
    public static let warnBeforeClosingTabPath = ["app", "warnBeforeClosingTab"]
    public static let warnBeforeClosingAgentSessionPath = ["app", "warnBeforeClosingAgentSession"]
    /// Both warnings when unset or invalid.
    public static let closeWarningFallback = true

    /// `app.warnBeforeClosingTab`.
    public var warnBeforeClosingTab: Bool { closeWarning(Self.warnBeforeClosingTabPath) }
    /// `app.warnBeforeClosingAgentSession`.
    public var warnBeforeClosingAgentSession: Bool { closeWarning(Self.warnBeforeClosingAgentSessionPath) }

    private func closeWarning(_ path: [String]) -> Bool {
        root.value(at: path)?.boolValue ?? Self.closeWarningFallback
    }

    /// One diagnostic per close warning key set to something other than a bool.
    static func closeWarningDiagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        [warnBeforeClosingTabPath, warnBeforeClosingAgentSessionPath].compactMap { path in
            guard let value = root.value(at: path), value.boolValue == nil else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false")
        }
    }
}
