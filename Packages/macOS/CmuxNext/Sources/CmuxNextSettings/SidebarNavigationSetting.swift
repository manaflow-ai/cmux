public import CmuxNextDesign

/// `sidebar.numbering`, `sidebar.cmd9`, `sidebar.stepping` and
/// `sidebar.steppingWraps` in cmux.json (SIDEBAR-NUMBERING-AND-STEPPING):
/// how Cmd-1…9 and Cmd-Ctrl-[ / ] walk the sidebar. A missing key is its
/// default; a bad value is the default plus a diagnostic.
public nonisolated struct SidebarNavigationSetting {
    public nonisolated init() {}
    public static let numberingPath = ["sidebar", "numbering"]
    public static let cmd9Path = ["sidebar", "cmd9"]
    public static let steppingPath = ["sidebar", "stepping"]
    public static let steppingWrapsPath = ["sidebar", "steppingWraps"]

    static func parse(_ root: JSONValue, into result: inout SidebarNavigationSettings, diagnostics: inout [SettingsDiagnostic]) {
        result.numbering = choice(root, numberingPath, fallback: result.numbering, &diagnostics)
        result.cmd9 = choice(root, cmd9Path, fallback: result.cmd9, &diagnostics)
        result.stepping = choice(root, steppingPath, fallback: result.stepping, &diagnostics)
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

    static func descriptors(group: SettingText) -> [SettingDescriptor] {
        let defaults = SidebarNavigationSettings.defaults
        let every = SettingsText.keyed("settings.sidebar.scope.allItems", "Every Item")
        let workspaces = SettingsText.keyed("settings.sidebar.scope.workspacesOnly", "Workspaces Only")
        let scope = [SettingChoice(SidebarNavigationSettings.Scope.allItems.rawValue, every),
                     SettingChoice(SidebarNavigationSettings.Scope.workspacesOnly.rawValue, workspaces)]
        return [
            SettingDescriptor(numberingPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.numbering", "Command-Number Shortcuts"),
                              help: SettingsText.keyed("settings.sidebar.numbering.help",
                                                       "Every item: Home is Command-1, the App Store Command-2, the first workspace Command-3. Workspaces only: the first workspace is Command-1."),
                              kind: .choice(scope), default: .string(defaults.numbering.rawValue),
                              keywords: ["sidebar", "shortcut", "number", "command", "home", "workspace"]),
            SettingDescriptor(cmd9Path, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.cmd9", "Command-9"),
                              help: SettingsText.keyed("settings.sidebar.cmd9.help", "Goes to the last item, as in browsers, or to the ninth."),
                              kind: .choice([
                                  SettingChoice(SidebarNavigationSettings.NinthKey.last.rawValue,
                                                SettingsText.keyed("settings.sidebar.cmd9.last", "Last Item")),
                                  SettingChoice(SidebarNavigationSettings.NinthKey.ninth.rawValue,
                                                SettingsText.keyed("settings.sidebar.cmd9.ninth", "Ninth Item")),
                              ]),
                              default: .string(defaults.cmd9.rawValue), keywords: ["sidebar", "shortcut", "nine", "last"]),
            SettingDescriptor(steppingPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.stepping", "Next and Previous Item"),
                              help: SettingsText.keyed("settings.sidebar.stepping.help",
                                                       "What Command-Control-] and Command-Control-[ step through."),
                              kind: .choice(scope), default: .string(defaults.stepping.rawValue),
                              keywords: ["sidebar", "next", "previous", "step", "shortcut"]),
            SettingDescriptor(steppingWrapsPath, section: .appearance, group: group,
                              title: SettingsText.keyed("settings.sidebar.steppingWraps", "Wrap Around"),
                              help: SettingsText.keyed("settings.sidebar.steppingWraps.help",
                                                       "Past the last item, the next item is the first again."),
                              kind: .toggle, default: .bool(defaults.steppingWraps),
                              keywords: ["sidebar", "next", "previous", "wrap"]),
        ]
    }
}
