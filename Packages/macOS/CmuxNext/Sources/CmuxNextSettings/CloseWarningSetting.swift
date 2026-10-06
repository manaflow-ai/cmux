/// `app.warnBeforeClosingTab` and `app.warnBeforeClosingAgentSession`, the
/// keys classic uses (#17430). Closing a tab or a workspace asks once while
/// a terminal runs a program; an agent at work in a terminal gets its own
/// question and its own toggle. Both are on when unset or invalid; the
/// question's "Don't ask again" turns its toggle off.
public nonisolated enum CloseWarningSetting {
    public static let tabPath = ["app", "warnBeforeClosingTab"]
    public static let agentSessionPath = ["app", "warnBeforeClosingAgentSession"]
    public static let fallback = true

    static func value(_ root: JSONValue, _ path: [String]) -> Bool {
        root.value(at: path)?.boolValue ?? fallback
    }

    /// One diagnostic per key that is set to something other than a bool.
    static func diagnostics(_ root: JSONValue) -> [SettingsDiagnostic] {
        [tabPath, agentSessionPath].compactMap { path in
            guard let value = root.value(at: path), value.boolValue == nil else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected true or false")
        }
    }
}

nonisolated extension CmuxConfigSnapshot {
    /// `app.warnBeforeClosingTab`; on when unset or invalid.
    public var warnBeforeClosingTab: Bool { CloseWarningSetting.value(root, CloseWarningSetting.tabPath) }
    /// `app.warnBeforeClosingAgentSession`; on when unset or invalid.
    public var warnBeforeClosingAgentSession: Bool { CloseWarningSetting.value(root, CloseWarningSetting.agentSessionPath) }
}
