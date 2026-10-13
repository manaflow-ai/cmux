public import CmuxNextDesign

/// `appearance.sidebarSurface` in cmux.json (`SidebarSurface`): "same" (the
/// default) draws the sidebar on the main pane's surface; "separate" shades
/// the sidebar and the chrome around the main pane darker, the look before.
/// A missing key is the default; a bad value is the default plus a
/// diagnostic.
public nonisolated struct SidebarSurfaceSetting: Sendable {
    public static let configPath = ["appearance", "sidebarSurface"]
    public static let fallback: SidebarSurface = .same

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> SidebarSurface {
        guard let value = root.value(at: configPath) else { return fallback }
        guard let text = value.stringValue, let surface = SidebarSurface(rawValue: text) else {
            let choices = SidebarSurface.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: configPath.joined(separator: "."),
                                                  message: "expected one of \(choices)"))
            return fallback
        }
        return surface
    }

    static func descriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            configPath, section: .appearance, group: group,
            title: SettingsText.keyed("settings.sidebar.surface", "Sidebar Background"),
            help: SettingsText.keyed("settings.sidebar.surface.help",
                                     "Same as Main Pane gives the sidebar the main pane's background. Separate shades the sidebar darker, as before."),
            kind: .choice([
                SettingChoice(SidebarSurface.same.rawValue, SettingsText.keyed("settings.choice.sidebarSurface.same", "Same as Main Pane")),
                SettingChoice(SidebarSurface.separate.rawValue, SettingsText.keyed("settings.choice.sidebarSurface.separate", "Separate")),
            ]),
            default: .string(fallback.rawValue),
            keywords: ["sidebar", "background", "surface", "shade", "color", "colour", "panel", "separate", "main pane"]
        )
    }
}

extension SettingsApplier {
    /// Copies `appearance.sidebarSurface` into `design`, writing only a change.
    static func applySidebarSurface(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        var ignored: [SettingsDiagnostic] = [] // the parse reported them (`ChromePlacementSetting.parse`)
        let surface = SidebarSurfaceSetting.parse(snapshot.root, diagnostics: &ignored)
        if design.sidebarSurface != surface { design.sidebarSurface = surface }
    }
}
