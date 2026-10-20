public import AppKit
import CmuxNextDesign
import CmuxNextFloating

/// The Chief's face when its profile sets no picture and no text: the Chief pet's character
/// (`home.chiefPetMascot` through `DesignSettings.homeChiefPetMascot`, Orb by default), so the
/// Chief looks the same in its header, on its Home tile, over the empty conversation and floating
/// over other apps. It replaced the bundled placeholder cat (Leo 2026-10-19: "I'm so tired of the
/// placeholder cat icon").
@MainActor
public enum HomeChiefFace {
    /// The character the setting names.
    static var mascot: ChiefPetMascot { ChiefPetMascot(setting: DesignSettings.shared.homeChiefPetMascot) }

    /// The header disc's and the empty conversation's picture.
    public static var picture: NSImage? { mascot.image }

    /// The Home list tile's picture (`HomeService.refreshChiefAvatar`).
    public static var tile: HomeChiefAvatar? { mascot.imageURL.map(HomeChiefAvatar.picture) }
}
