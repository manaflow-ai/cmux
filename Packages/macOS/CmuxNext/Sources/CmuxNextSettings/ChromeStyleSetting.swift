public import CmuxNextActions
public import CmuxNextDesign

/// `appearance.chromeStyle` in cmux.json (`ChromeStyle`): one string for the
/// window's look, whose values supply the defaults of the curved main pane,
/// `layout.paneSeparation`, `sidebar.border` and `appearance.sidebarSurface`
/// (the table: schemas/settings/chrome-styles.json).
/// A key set in the file still wins over its style. A missing key is
/// `default`; a bad value is `default` plus a diagnostic.
public nonisolated struct ChromeStyleSetting: Sendable {
    public static let configPath = ["appearance", "chromeStyle"]
    public static let fallback: ChromeStyle = .default

    public init() {}

    /// The palette action that switches to `style`.
    public static func actionID(_ style: ChromeStyle) -> String { "appearance.chromeStyle.\(style.actionName)" }

    /// The file value for `style`: the default removes the key.
    public static func fileValue(_ style: ChromeStyle) -> JSONValue? {
        style == fallback ? nil : .string(style.rawValue)
    }

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> ChromeStyle {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let style = ChromeStyle(rawValue: text) else {
            let choices = ChromeStyle.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return style
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            configPath, section: .appearance, group: group,
            title: SettingsText.keyed("settings.appearance.chromeStyle", "Window Style"),
            help: SettingsText.keyed("settings.appearance.chromeStyle.help",
                                     "The look of the window: whether panes sit in one rounded card, and where lines are drawn. Separation, Sidebar Background and the sidebar border still win when you set them."),
            summary: SettingsText.keyed("settings.appearance.chromeStyle.summary", "Card, lines and sidebar background"),
            kind: .choice(ChromeStyle.allCases.map { SettingChoice($0.rawValue, title($0)) }),
            default: .string(fallback.rawValue),
            keywords: ["window", "style", "chrome", "card", "flat", "border", "borders", "lines", "divider", "outline",
                       "seam", "sidebar", "two-tone", "minimal", "bare"]
        )
    }
}

extension SettingsApplier {
    /// Copies `appearance.chromeStyle` into `design`, writing only a change.
    static func applyChromeStyle(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        if design.chromeStyle != snapshot.chromeStyle { design.chromeStyle = snapshot.chromeStyle }
    }
}

extension ChromeStyleSetting {
    /// Binds every `appearance.chromeStyle.<name>` palette action. `save`
    /// returns a refusal (the key is managed) before anything changes, else
    /// starts the cmux.json write and returns nil; the style then applies at
    /// once and the file watcher reapplies the same value.
    @MainActor public static func bindActions(
        into registry: ActionRegistry, design: DesignSettings,
        save: @escaping @MainActor (_ path: [String], _ value: JSONValue?) -> String?
    ) {
        for style in ChromeStyle.allCases {
            registry.bind(ActionID(rawValue: actionID(style)), invoke: { [weak registry] _ in
                if let refusal = save(configPath, fileValue(style)) {
                    registry?.refuse(refusal)
                    return
                }
                design.chromeStyle = style
            })
        }
    }
}
