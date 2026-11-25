/// One titled group of the app menu's Customizations submenu (`SettingsSchema.quickToggleGroups`).
public nonisolated struct QuickToggleGroup: Sendable, Equatable {
    public let title: String
    public let rows: [SettingDescriptor]
}

extension SettingsSchema {
    /// The app menu's Customizations submenu (Leo 2026-11-22, ask-931361017e: "some sort of checklist
    /// to be able to toggle through customizations", "as few clicks as reasonable"): Experiments (every
    /// `experiments.*` switch), then Labs (every `labs.*` switch and every other switch of the Labs
    /// group, such as `customize.fromTheApp`), in schema order. Only on/off rows the palette lists in
    /// this build, so a new schema row shows up here with no other edit; an empty group is left out.
    public static func quickToggleGroups(developerTools: Bool) -> [QuickToggleGroup] {
        let switches = all.filter { $0.kind == .toggle && $0.isPaletteListed(developerTools: developerTools) }
        let experiments = switches.filter { $0.path.first == "experiments" }
        let labs = switches.filter { $0.path.first != "experiments" && ($0.path.first == "labs" || $0.textKeys.group == "settings.group.labs") }
        return [
            QuickToggleGroup(title: SettingsText.text("settings.group.experiments", "Experiments"), rows: experiments),
            QuickToggleGroup(title: SettingsText.text("settings.group.labs", "Labs"), rows: labs),
        ].filter { !$0.rows.isEmpty }
    }
}

extension SettingsController {
    /// Whether the switch `descriptor` is on: the value in effect (the file over MDM's recommendation,
    /// a forced value over both, else this build's default).
    public func isOn(_ descriptor: SettingDescriptor) -> Bool {
        descriptor.effectiveValue(in: snapshot.root)?.boolValue ?? false
    }

    /// ``isOn(_:)`` for each of `descriptors` by key, in one Rust call (`schema.rows`), for a menu that
    /// lists many switches.
    public func onStates(_ descriptors: [SettingDescriptor]) -> [String: Bool] {
        SettingsSchema.reads(root: snapshot.root, keys: descriptors.map(\.id)).mapValues { $0.effective?.boolValue ?? false }
    }

    /// Whether a managed layer (MDM, team policy) holds `descriptor`, so a menu shows it disabled.
    public func isLocked(_ descriptor: SettingDescriptor) -> Bool {
        managedKeys[descriptor.id] != nil
    }

    /// Flips the switch `descriptor` for the person's click, through the one guarded write
    /// (`setSetting`: the managed guard and the schema check).
    public func flip(_ descriptor: SettingDescriptor) async throws {
        try await setSetting(descriptor, to: .bool(!isOn(descriptor)), by: .user)
    }
}
