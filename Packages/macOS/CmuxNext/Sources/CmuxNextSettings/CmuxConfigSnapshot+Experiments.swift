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

    /// The Forum's sidebar item, page and `forum.show` show: `experiments.forum` is on (off by default).
    public var showsForum: Bool { root.value(at: Self.forumPath)?.boolValue ?? Self.forumDefault }

    /// What a refused `forum.show` says while the experiment is off: the setting's title.
    public static var forumHiddenReason: String {
        SettingsSchema.descriptor(for: forumPath)?.title ?? forumPath.joined(separator: ".")
    }
}

extension SettingsSchema {
    /// The schema's `experiments.*` toggles, read once.
    static let experimentToggles: [SettingDescriptor] = all.filter {
        $0.path.count == 2 && $0.path[0] == "experiments" && $0.kind == .toggle
    }
}
