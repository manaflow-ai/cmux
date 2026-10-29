public import CmuxNextActions
public import CmuxNextAppearance
public import CmuxNextDesignTokens

/// `tabs.overflow` in cmux.json: "shrink" (default, Chrome's) or "scroll" (cx-kp9b4). The palette's
/// Tabs: Use Scrolling Tabs and Tabs: Use Shrinking Tabs (`tabs.overflow.scroll`, `tabs.overflow.shrink`)
/// and Settings write it. A crowded strip never asks: it scrolls, keeping the selected tab in view.
public nonisolated struct TabOverflowSetting: Sendable {
    public static let configPath = ["tabs", "overflow"]
    public static let fallback: TabOverflow = .shrink

    public init() {}

    /// A missing key is the default with no diagnostic; a bad value is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (TabOverflow, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let text = value.stringValue, let mode = TabOverflow(rawValue: text.lowercased()) else {
            let choices = TabOverflow.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "tabs.overflow", message: "expected one of \(choices)"))
        }
        return (mode, nil)
    }
}

extension TabOverflowSetting {
    /// Tabs: Use Scrolling Tabs and Tabs: Use Shrinking Tabs (`tabs.overflow.scroll`, `tabs.overflow.shrink`):
    /// each saves its value (shrink, the default, removes the key; refused while the key is managed) and
    /// applies it at once. No preview: a highlighted palette row must not reflow every tab strip.
    @MainActor public static func bindActions(into registry: ActionRegistry, design: DesignSettings, save: @escaping SettingChoiceActions.Save) {
        SettingChoiceActions.bind(TabOverflow.allCases, into: registry, id: { "tabs.overflow.\($0.rawValue)" }, path: configPath,
                                  fileValue: fileValue, save: save) { design.tabOverflow = $0 }
    }

    /// The cmux.json value: the default (shrink) removes the key.
    public static func fileValue(_ mode: TabOverflow) -> JSONValue? { mode == fallback ? nil : .string(mode.rawValue) }
}
