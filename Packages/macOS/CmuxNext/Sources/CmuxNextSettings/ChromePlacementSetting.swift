public import CmuxNextDesign

/// Where the window chrome sits (R109): `sidebar.side` and
/// `sidebar.spacesPosition` in cmux-next.json. A missing key is the
/// default; a bad value is the default plus a diagnostic.
public nonisolated enum ChromePlacementSetting {
    public static let sidebarSidePath = ["sidebar", "side"]
    public static let spacesPositionPath = ["sidebar", "spacesPosition"]

    static func parse(_ root: JSONValue, into snapshot: inout CmuxConfigSnapshot) {
        snapshot.sidebarSide = choice(root, sidebarSidePath, fallback: .left, &snapshot.diagnostics)
        snapshot.spacesPosition = choice(root, spacesPositionPath, fallback: .bottom, &snapshot.diagnostics)
    }

    private static func choice<Value: RawRepresentable & CaseIterable>(
        _ root: JSONValue, _ path: [String], fallback: Value, _ diagnostics: inout [SettingsDiagnostic]
    ) -> Value where Value.RawValue == String {
        guard let value = root.value(at: path) else { return fallback }
        guard let text = value.stringValue, let parsed = Value(rawValue: text) else {
            let choices = Value.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: path.joined(separator: "."), message: "expected one of \(choices)"))
            return fallback
        }
        return parsed
    }

    static func sidebarSideDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(sidebarSidePath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.side", "Sidebar Side"),
                          help: SettingsText.keyed("settings.sidebar.side.help",
                                                   "The window edge the sidebar sits on. On the right, the window buttons sit over the tab bar."),
                          kind: .choice([
                              SettingChoice(SidebarSide.left.rawValue, SettingsText.keyed("settings.choice.left", "Left")),
                              SettingChoice(SidebarSide.right.rawValue, SettingsText.keyed("settings.choice.right", "Right")),
                          ]),
                          default: .string(SidebarSide.left.rawValue),
                          keywords: ["sidebar", "side", "left", "right", "position", "edge", "layout"])
    }

    static func spacesPositionDescriptor(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(spacesPositionPath, section: .appearance, group: group,
                          title: SettingsText.keyed("settings.sidebar.spacesPosition", "Spaces Position"),
                          help: SettingsText.keyed("settings.sidebar.spacesPosition.help",
                                                   "Where the spaces dots sit in the sidebar: under the window buttons or above the Settings row."),
                          kind: .choice([
                              SettingChoice(SpacesPosition.top.rawValue, SettingsText.keyed("settings.choice.top", "Top")),
                              SettingChoice(SpacesPosition.bottom.rawValue, SettingsText.keyed("settings.choice.bottom", "Bottom")),
                          ]),
                          default: .string(SpacesPosition.bottom.rawValue),
                          keywords: ["sidebar", "spaces", "rooms", "profiles", "dots", "top", "bottom", "position", "layout"])
    }
}

extension SettingsApplier {
    /// Copies the chrome placement keys into `design`, writing only changes.
    public static func applyPlacement(_ snapshot: CmuxConfigSnapshot, to design: DesignSettings) {
        if design.sidebarSide != snapshot.sidebarSide { design.sidebarSide = snapshot.sidebarSide }
        if design.spacesPosition != snapshot.spacesPosition { design.spacesPosition = snapshot.spacesPosition }
    }
}
