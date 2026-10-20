public import CmuxNextActions

/// `home.chiefPetEnabled` in cmux.json: the Chief pet, a small Chief that floats over every app,
/// pops up agent events and takes a quick reply (CmuxNextFloating's `ChiefPetController`). Off by
/// default; the person turns it on (Settings > Home > Chief Pet, View > Show Chief Pet, the palette's
/// Show Chief Pet, the empty Chief conversation); agents may not (it puts their output over every app).
/// `home.chiefPetMascot` picks its character among the Chief Dock's nine pixel mascots.
public nonisolated struct HomeChiefPetSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "chiefPetEnabled"]
    public static let mascotPath = ["home", "chiefPetMascot"]
    /// The Chief Dock's mascot ids (`ChiefPetMascot`, webviews `ChiefMascot`), its default first.
    public static let mascots = ["orb", "orb-spark", "orb-hood", "machine", "machine-cyan", "machine-blue", "moon", "moon-blue", "fox"]
    public static let defaultMascot = "orb"

    /// The mascot id; one that is not a mascot is the default plus a diagnostic.
    static func parseMascot(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: mascotPath) else { return (defaultMascot, nil) }
        guard let id = value.stringValue, mascots.contains(id) else {
            return (defaultMascot, SettingsDiagnostic(kind: .invalidValue, path: mascotPath.joined(separator: "."),
                                                      message: "expected one of " + mascots.joined(separator: ", ")))
        }
        return (id, nil)
    }
}

extension HomeChiefPetSetting {
    /// Show Chief Pet / Hide Chief Pet (`home.toggleChiefPet`; the View menu and the palette):
    /// flips `home.chiefPetEnabled` as the caller. The row and the menu item read as the change they
    /// make (Hide Chief Pet while it shows). Only a person may turn it on or off: the settings layer
    /// refuses an agent's write (the key is not agent-settable), and the action is person-only, so
    /// the control socket refuses it too. `unavailable` is the refusal while
    /// settings are not loaded.
    public static let toggleAction: ActionID = "home.toggleChiefPet"

    /// The toggle's title while the pet shows.
    public static var hideTitle: String { SettingsText.text("chiefPet.hide", "Hide Chief Pet") }

    @MainActor public func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                unavailable: String) {
        registry.bind(Self.toggleAction, invoke: { invocation in
            guard let settings = settings() else { return registry.refuse(unavailable) }
            let on = !settings.snapshot.homeChiefPetEnabled
            let writer = SettingWriter(invocation.origin)
            registry.track(ActionWork {
                do { try await settings.setSetting(at: Self.configPath, to: .bool(on), by: writer) } catch {
                    return ActionWorkFailure(refusal: .unavailable, reason: String(describing: error))
                }
                return nil
            })
        })
        let title: @MainActor () -> String? = { settings()?.snapshot.homeChiefPetEnabled == true ? Self.hideTitle : nil }
        ActionTargetTitles.set(Self.toggleAction, in: registry) { _ in title() }
        ActionTargetTitles.setPaletteTitle(Self.toggleAction, in: registry, title)
    }
}

/// The Home settings' palette and CLI toggles: Enable / Disable Channels and Show / Hide Chief Pet,
/// bound together so the App target binds them in one call.
public enum HomeSettingActions {
    @MainActor public static func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                       unavailable: String) {
        HomeChannelsSetting().bind(into: registry, settings: settings, unavailable: unavailable)
        HomeChiefPetSetting().bind(into: registry, settings: settings, unavailable: unavailable)
    }
}
