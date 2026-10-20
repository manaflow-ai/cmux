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
        let toggles = ChiefPetToggles()
        registry.bind(Self.toggleAction, invoke: { invocation in
            guard let settings = settings() else { return registry.refuse(unavailable) }
            // A run while an earlier write is in flight flips that write's value, not the stale
            // snapshot, and writes after it: two quick runs put the pet back as it was.
            let on = !(toggles.pending ?? settings.snapshot.homeChiefPetEnabled)
            toggles.pending = on
            let previous = toggles.last
            let writer = SettingWriter(invocation.origin)
            // task-owner: one write, after the previous run's; ends with the reload
            let work = ActionWork { @MainActor in
                _ = await previous?.value
                defer { if toggles.pending == on { toggles.pending = nil } }
                do { try await settings.setSetting(at: Self.configPath, to: .bool(on), by: writer) } catch {
                    return ActionWorkFailure(refusal: .unavailable, reason: String(describing: error))
                }
                return nil
            }
            toggles.last = work
            registry.track(work)
        })
        let title: @MainActor () -> String? = {
            (toggles.pending ?? settings()?.snapshot.homeChiefPetEnabled) == true ? Self.hideTitle : nil
        }
        ActionTargetTitles.set(Self.toggleAction, in: registry) { _ in title() }
        ActionTargetTitles.setPaletteTitle(Self.toggleAction, in: registry, title)
    }
}

extension HomeChiefPetSetting {
    /// Message the Chief (`home.messageChiefPet`; the palette, and a shortcut a person can bind): the
    /// pet with its reply box open. Off, it turns `home.chiefPetEnabled` on as the person first, then
    /// `summon` runs once the write has landed; on, `summon` runs at once. Person-only, like the
    /// toggle: an agent can neither turn the pet on nor put a box that takes the keys over every app.
    public static let messageAction: ActionID = "home.messageChiefPet"

    @MainActor public func bindMessage(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                       unavailable: String, summon: @escaping @MainActor () -> Void) {
        registry.bind(Self.messageAction, invoke: { invocation in
            // The control socket refuses a person-only action first; an in-app run from elsewhere stops here,
            // with the settings layer's own words for a user-only key.
            guard invocation.origin == .user else {
                return registry.refuse(SettingUserOnly(key: Self.configPath.joined(separator: "."), writer: SettingWriter(invocation.origin)).description)
            }
            guard let settings = settings() else { return registry.refuse(unavailable) }
            guard !settings.snapshot.homeChiefPetEnabled else { return summon() }
            // task-owner: one write; ends with the reload, then the summon
            let work = ActionWork { @MainActor in
                do { try await settings.setSetting(at: Self.configPath, to: .bool(true), by: .user) } catch {
                    return ActionWorkFailure(refusal: .unavailable, reason: String(describing: error))
                }
                summon()
                return nil
            }
            registry.track(work)
        })
    }
}

/// The toggle's runs in flight: the value the newest one writes and its work, so the next run
/// flips that value and waits for it.
@MainActor final class ChiefPetToggles {
    var pending: Bool?
    var last: ActionWork?
}

/// The Home settings' palette and menu toggles: Enable / Disable Channels and Show / Hide Chief Pet,
/// bound together so the App target binds them in one call.
public nonisolated struct HomeSettingActions {
    public nonisolated init() {}

    /// `summonChiefPet`: the pet with its reply box open (Message the Chief), the App's `ChiefPetController.summon`.
    @MainActor public func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                unavailable: String, summonChiefPet: @escaping @MainActor () -> Void = {}) {
        HomeChannelsSetting().bind(into: registry, settings: settings, unavailable: unavailable)
        HomeChiefPetSetting().bind(into: registry, settings: settings, unavailable: unavailable)
        HomeChiefPetSetting().bindMessage(into: registry, settings: settings, unavailable: unavailable, summon: summonChiefPet)
    }
}
