import AppKit
import CmuxNextCompat
import CmuxNextFloating
import CmuxNextHome
import CmuxNextSettings

/// The Chief's face when its profile sets no picture and no text: the Chief pet's character
/// (`home.chiefPetMascot`, Orb by default), so the Chief looks the same in its header, on its
/// Home tile, over the empty conversation and floating over other apps. It replaced the
/// bundled placeholder cat (Leo 2026-10-19: "I'm so tired of the placeholder cat icon").
@MainActor
enum HomeChiefFace {
    /// The character `home.chiefPetMascot` names (Orb without settings).
    static func mascot(_ settings: SettingsController?) -> ChiefPetMascot {
        ChiefPetMascot(setting: settings?.snapshot.homeChiefPetMascot ?? HomeChiefPetSetting.defaultMascot)
    }

    /// The header disc's picture (`HomeHostView.loadAvatar`).
    static func picture(_ settings: SettingsController?) -> NSImage? { mascot(settings).image }

    /// The Home list tile's picture (`HomeService.refreshChiefAvatar`).
    static func tile(_ settings: SettingsController?) -> HomeChiefAvatar? { mascot(settings).imageURL.map(HomeChiefAvatar.picture) }

    /// Follows the character and whether the pet shows, for as long as the returned task runs:
    /// `changed` gets the character's art and the pet's state, once at once and on each change.
    static func follow(_ services: AppServices, changed: @escaping @MainActor (NSImage?, Bool) -> Void) -> Task<Void, Never> {
        // task-owner: the caller's view; event-driven (Observation of the settings snapshot)
        Task { [weak services] in
            for await (mascot, shown) in ObservationStream({ () -> (String, Bool) in
                let snapshot = services?.settings?.snapshot
                return (snapshot?.homeChiefPetMascot ?? HomeChiefPetSetting.defaultMascot, snapshot?.homeChiefPetEnabled ?? false)
            }) {
                changed(ChiefPetMascot(setting: mascot).image, shown)
            }
        }
    }
}
