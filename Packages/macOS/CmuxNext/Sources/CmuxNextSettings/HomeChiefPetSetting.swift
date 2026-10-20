public import CmuxNextActions

/// `home.chiefPetEnabled` in cmux.json: the Chief pet, a small Chief that floats over every app,
/// pops up agent events and takes a quick reply (CmuxNextFloating's `ChiefPetController`). Off by
/// default; the person or an agent turns it on (Settings > Home > Chief Pet, View > Show Chief Pet, the
/// palette's Show Chief Pet, the empty Chief conversation, `cmux settings set`), and the person can hide
/// it again the same way.
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
    /// make (Hide Chief Pet while it shows). The action is person-only, so the control socket refuses
    /// an agent's run; an agent turns the pet on or off with `cmux settings set` (the key is
    /// agent-settable). `unavailable` is the refusal while settings are not loaded.
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

    @MainActor public func bind(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?,
                                unavailable: String) {
        HomeChannelsSetting().bind(into: registry, settings: settings, unavailable: unavailable)
        HomeChiefPetSetting().bind(into: registry, settings: settings, unavailable: unavailable)
    }
}
