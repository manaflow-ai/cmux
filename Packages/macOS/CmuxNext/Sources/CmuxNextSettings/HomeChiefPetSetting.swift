public import CmuxNextActions

/// `home.chiefPetEnabled` in cmux.json: the Chief pet, a small Chief that floats over every app,
/// pops up agent events and takes a quick reply (CmuxNextFloating's `ChiefPetController`). Off by
/// default; the person or an agent turns it on (Settings > Home > Chief Pet, View > Show Chief Pet, the
/// palette's Show Chief Pet, the empty Chief conversation, `cmux settings set`), and the person can
/// hide it again the same way. Message the Chief shows it for one message without turning it on.
/// `home.chiefPetMascot` picks its character among the Chief Dock's pixel mascots, Series 2 and the animated sets.
public nonisolated struct HomeChiefPetSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "chiefPetEnabled"]
    public static let mascotPath = ["home", "chiefPetMascot"]
    /// The characters' ids in the picker's order (`ChiefPetMascot`, webviews `ChiefMascot`): Series 1
    /// without the orbs, Mochi, Series 2, then the orbs. A pick is kept by id, so the order moves no
    /// one's character, and the default stays orb wherever it sits in the list.
    public static let mascots = ["fox", "machine", "machine-cyan", "machine-blue", "moon", "moon-blue", "mochi",
                                 "fox-arctic", "machine-violet", "machine-gold", "moon-rose", "orb", "orb-spark", "orb-hood"]
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
    /// make (Hide Chief Pet while it shows). The action is person-only, so the control socket refuses
    /// an agent's run; an agent turns the pet on or off with `cmux settings set` (the key is
    /// agent-settable). `unavailable` is the refusal while settings are not loaded.
    public static let toggleAction: ActionID = "home.toggleChiefPet"

    /// The toggle's title while the pet shows.
    public static var hideTitle: String { SettingsText.text("chiefPet.hide", "Hide Chief Pet") }

    /// `toggles` is shared with Message the Chief, which waits for the toggle's write.
    @MainActor public func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                unavailable: String) {
        bind(into: registry, settings: settings, unavailable: unavailable, toggles: ChiefPetToggles())
    }

    @MainActor func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                         unavailable: String, toggles: ChiefPetToggles) {
        // A managed `home.chiefPetEnabled` cannot change: the View menu, the palette and the pet's Hide grey out.
        registry.bind(Self.toggleAction, isEnabled: { settings()?.managedKeys[Self.configPath.joined(separator: ".")] == nil },
                      invoke: { invocation in
            guard let settings = settings() else { return registry.refuse(unavailable) }
            // A run while an earlier write is in flight flips that write's value, not the stale
            // snapshot, and writes after it: two quick runs put the pet back as it was. `on` (the
            // pet's own Hide passes false) sets the value instead of flipping it, in the same order.
            let on = invocation.arguments["on"]?.boolValue ?? !(toggles.pending ?? settings.snapshot.homeChiefPetEnabled)
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
    /// pet with its reply box open. It never writes `home.chiefPetEnabled`: `summon` gets the value that
    /// applies, and with the pet off the App shows it for this message only (`ChiefPetController.summon`),
    /// so a person who never chose the pet does not keep it. Person-only, like the toggle: an agent
    /// cannot put a box that takes the keys over every app.
    public static let messageAction: ActionID = "home.messageChiefPet"
    /// Message the Chief from Any App: its system-wide key (Ctrl-Opt-Cmd-C). Enabled only while the pet is
    /// on, so GlobalHotKeyService registers it only then (`ActionRegistry.globalHotKeys`); with the pet off
    /// the key stays with other apps.
    public static let messageFromAnyAppAction: ActionID = "home.messageChiefFromAnyApp"

    /// `summon(petOn)`: `petOn` is `home.chiefPetEnabled` once any toggle in flight has landed.
    @MainActor public func bindMessage(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                       unavailable: String, summon: @escaping @MainActor (_ petOn: Bool) -> Void) {
        bindMessage(into: registry, settings: settings, unavailable: unavailable, toggles: ChiefPetToggles(), summon: summon)
    }

    /// With the toggle's `toggles`: a run while Show / Hide Chief Pet's write is in flight waits for it and
    /// summons with the value it lands.
    @MainActor func bindMessage(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                unavailable: String, toggles: ChiefPetToggles, summon: @escaping @MainActor (_ petOn: Bool) -> Void) {
        let message: @MainActor (ActionInvocation) -> Void = { invocation in
            // The control socket refuses a person-only action first; an in-app run from elsewhere stops here,
            // with the settings layer's own words for a user-only key.
            guard invocation.origin == .user else {
                return registry.refuse(SettingUserOnly(key: Self.configPath.joined(separator: "."), writer: SettingWriter(invocation.origin)).description)
            }
            guard let settings = settings() else { return registry.refuse(unavailable) }
            guard toggles.pending != nil, let previous = toggles.last else { return summon(settings.snapshot.homeChiefPetEnabled) }
            // task-owner: a wait for the toggle's in-flight write; ends with the summon
            let work = ActionWork { @MainActor in
                _ = await previous.value
                summon(settings.snapshot.homeChiefPetEnabled)
                return nil
            }
            registry.track(work)
        }
        registry.bind(Self.messageAction, invoke: message)
        registry.bind(Self.messageFromAnyAppAction, isEnabled: { settings()?.snapshot.homeChiefPetEnabled == true }, invoke: message)
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
                                unavailable: String, summonChiefPet: @escaping @MainActor (_ petOn: Bool) -> Void) {
        HomeChannelsSetting().bind(into: registry, settings: settings, unavailable: unavailable)
        let toggles = ChiefPetToggles()
        HomeChiefPetSetting().bind(into: registry, settings: settings, unavailable: unavailable, toggles: toggles)
        HomeChiefPetSetting().bindMessage(into: registry, settings: settings, unavailable: unavailable, toggles: toggles, summon: summonChiefPet)
    }
}
