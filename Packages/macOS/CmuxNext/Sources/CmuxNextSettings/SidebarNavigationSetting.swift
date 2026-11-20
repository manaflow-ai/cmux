public import CmuxNextDesign

/// `sidebar.numbering`, `sidebar.cmd9`, `sidebar.stepping` and
/// `sidebar.steppingWraps` in cmux.json (SIDEBAR-NUMBERING-AND-STEPPING):
/// how Cmd-1…9 and Cmd-Ctrl-[ / ] walk the sidebar. A missing key is its
/// default; a bad value is the default plus a diagnostic.
public nonisolated struct SidebarNavigationSetting {
    public nonisolated init() {}
    // The paths and defaults are generated from schemas/settings/source/sidebar.json.

    static func parse(_ root: JSONValue, into result: inout SidebarNavigationSettings, diagnostics: inout [SettingsDiagnostic]) {
        result.numbering = choice(root, numberingPath, fallback: numberingDefault, &diagnostics)
        result.cmd9 = choice(root, cmd9Path, fallback: cmd9Default, &diagnostics)
        result.stepping = choice(root, steppingPath, fallback: steppingDefault, &diagnostics)
        result.steppingWraps = steppingWrapsDefault
        if let value = root.value(at: steppingWrapsPath) {
            if let flag = value.boolValue {
                result.steppingWraps = flag
            } else {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "sidebar.steppingWraps", message: "expected true or false"))
            }
        }
    }

    private static func choice<T: RawRepresentable & CaseIterable>(_ root: JSONValue, _ path: [String], fallback: T,
                                                                     _ diagnostics: inout [SettingsDiagnostic]) -> T where T.RawValue == String {
        guard let value = root.value(at: path) else { return fallback }
        if let text = value.stringValue, let parsed = T(rawValue: text) { return parsed }
        let choices = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of " + choices))
        return fallback
    }
}
