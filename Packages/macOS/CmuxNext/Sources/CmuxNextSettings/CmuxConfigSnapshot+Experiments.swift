/// Settings > Advanced > Experiments (`experiments.*` in cmux.json, schemas/settings/source/experiments.json):
/// taste prototypes, one toggle each, all off by default. The agent pages get every one as one object
/// (AgentPanePageSettings), so a new prototype adds only its schema row.
extension CmuxConfigSnapshot {
    /// Every `experiments.*` toggle by its last path part (`glassToolbarGroups`): a bool in cmux.json,
    /// else the row's default.
    public var experimentSwitches: [String: Bool] {
        var switches: [String: Bool] = [:]
        for row in SettingsSchema.experimentToggles {
            switches[row.path[1]] = root.value(at: row.path)?.boolValue ?? row.defaultValue?.boolValue ?? false
        }
        return switches
    }
}

extension SettingsSchema {
    /// The schema's `experiments.*` toggles, read once.
    static let experimentToggles: [SettingDescriptor] = all.filter {
        $0.path.count == 2 && $0.path[0] == "experiments" && $0.kind == .toggle
    }
}
