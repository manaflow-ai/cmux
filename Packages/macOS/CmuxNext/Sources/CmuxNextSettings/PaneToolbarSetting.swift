/// The pane toolbar's hidden buttons in cmux.json (cx-kk7lm):
///
/// ```jsonc
/// "tabs": { "hiddenButtons": ["splitDown"] }
/// ```
///
/// The action ids of the buttons right-clicked away (Hide Split Down Button) from the toolbar at
/// the tab bar's trailing end, in every pane; the toolbar's right-click shows them again. A bad
/// item is dropped with a diagnostic.
public nonisolated struct PaneToolbarSetting: Sendable, Hashable {
    public static let hiddenButtonsPath = ["tabs", "hiddenButtons"]

    /// The hidden buttons' action ids.
    public var hidden: Set<String> = []

    /// The setting in `root` (the file's whole JSON).
    public init(_ root: JSONValue) {
        var diagnostics: [SettingsDiagnostic] = []
        hidden = Self.parse(root, diagnostics: &diagnostics)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Set<String> {
        guard let value = root.value(at: hiddenButtonsPath) else { return [] }
        let id = hiddenButtonsPath.joined(separator: ".")
        guard case .array(let items) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected an array of action ids"))
            return []
        }
        let ids = items.compactMap { $0.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        if ids.count != items.count {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: id, message: "expected action ids (non-empty strings)"))
        }
        return Set(ids)
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            hiddenButtonsPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.hiddenButtons", "Hidden Tab Bar Buttons"),
            help: SettingsText.keyed("settings.tabs.hiddenButtons.help",
                                     "Action ids of the buttons hidden from the tab bar. Right-click a button to hide it, the tab bar's buttons to show it again."),
            kind: .stringList, default: .array([]), keywords: ["toolbar", "split", "buttons", "hide"]
        )
        // Raw action ids mean nothing on the page; the buttons' right-click hides and shows them.
        .hiddenFromSettingsPage("action ids; toggled from the tab bar buttons' right-click")
    }
}
