/// `tabs.tabBar.terminal`, `tabs.tabBar.browser` and `tabs.tabBar.agent` in
/// cmux.json (cx-soza): whether a pane of that kind shows its horizontal tab
/// bar. Automatic shows it for terminals and browsers and hides it for an
/// agent chat alone in its column or in the chat dock until it holds two
/// tabs. A pane's own Show Tab Bar choice wins over its kind's.
public nonisolated enum PaneTabBarMode: String, Sendable, CaseIterable {
    case auto
    case always
    case never
}

/// What a pane holds, for its tab bar default: agent chats only, browsers
/// only, or anything else (terminals, mixed, empty).
public nonisolated enum PaneTabBarKind: String, Sendable, CaseIterable {
    case terminal
    case browser
    case agent
}

public nonisolated struct PaneTabBarDefaults: Equatable, Sendable {
    public var terminal: PaneTabBarMode = .auto
    public var browser: PaneTabBarMode = .auto
    public var agent: PaneTabBarMode = .auto

    public init() {}

    public subscript(kind: PaneTabBarKind) -> PaneTabBarMode {
        get {
            switch kind {
            case .terminal: terminal
            case .browser: browser
            case .agent: agent
            }
        }
        set {
            switch kind {
            case .terminal: terminal = newValue
            case .browser: browser = newValue
            case .agent: agent = newValue
            }
        }
    }
}

nonisolated extension PaneTabBarKind {
    /// This kind's key in cmux.json: `tabs.tabBar.<kind>`.
    public var settingsPath: [String] { ["tabs", "tabBar", rawValue] }
}

nonisolated extension PaneTabBarDefaults {
    /// A missing key is Automatic with no diagnostic; a bad value is
    /// Automatic plus a diagnostic.
    static func parse(_ root: JSONValue) -> (PaneTabBarDefaults, [SettingsDiagnostic]) {
        var defaults = PaneTabBarDefaults()
        var diagnostics: [SettingsDiagnostic] = []
        for kind in PaneTabBarKind.allCases {
            guard let value = root.value(at: kind.settingsPath) else { continue }
            guard let text = value.stringValue, let mode = PaneTabBarMode(rawValue: text) else {
                let choices = PaneTabBarMode.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: kind.settingsPath.joined(separator: "."),
                                                      message: "expected one of \(choices)"))
                continue
            }
            defaults[kind] = mode
        }
        return (defaults, diagnostics)
    }
}
