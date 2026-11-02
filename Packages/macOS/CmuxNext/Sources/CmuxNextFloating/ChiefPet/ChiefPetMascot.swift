public import AppKit

/// The Chief pet's character: the Chief Dock's nine pixel mascots (#21194, its `ChiefMascot`
/// ids), bundled at 256 px wide, the four animated avatar sets (Mochi, Captain, Sprout and Bolt,
/// `scripts/cmux-next/art/chief_mascot_animated.py`), and Series 2, new colourways of Fox, Machine
/// and Moon (`scripts/cmux-next/art/chief_mascot_series2.py`). The cases are in the picker's order:
/// Series 1 without the orbs, the animated sets, Series 2, then the orbs (Leo 2026-11-01: "we can
/// reorder them a little bit so they orb doesn't come first"). A choice is kept by its id, never its
/// place, so the order changes nobody's pick, and Orb stays the default (`initial`).
public nonisolated enum ChiefPetMascot: String, CaseIterable, Sendable {
    case fox
    case machine
    case machineCyan = "machine-cyan"
    case machineBlue = "machine-blue"
    case moon
    case moonBlue = "moon-blue"
    /// The first animated set (`cmux-avatar/1`, webviews avatars/sets/mochi); still here, its idle frame.
    case mochi
    /// The other animated sets Codex drew (#25213; Leo 2026-10-26: "We need to be getting Codex to,
    /// like, generate some more animated stuff"): each steps its state rows in the pet, like Mochi.
    case captain
    case sprout
    case bolt
    // Series 2.
    case foxArctic = "fox-arctic"
    case machineViolet = "machine-violet"
    case machineGold = "machine-gold"
    case moonRose = "moon-rose"
    case orb
    case orbSpark = "orb-spark"
    case orbHood = "orb-hood"

    public static let initial = ChiefPetMascot.orb

    /// The bundled PNG's name.
    var resource: String {
        "ChiefMascot" + rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    public var image: NSImage? { Bundle.module.image(forResource: resource) }

    /// An animated character's sheet (`ChiefMascot<Name>Sheet.png` with its `.json`); nil for a still one.
    var sprite: ChiefPetSprite? { ChiefPetSprite.bundled(resource) }

    /// The character as a Chief avatar: whole, centered on a transparent square with room
    /// around it (`…Avatar.png`), so a round avatar (the Home header and list, New Message)
    /// shows all of it and no disc behind it.
    public var avatarURL: URL? { Bundle.module.url(forResource: resource + "Avatar", withExtension: "png") }

    /// The character picker's label beside Show Chief Pet (the Chief Settings popover).
    public static var pickerTitle: String {
        String(localized: "chiefPet.mascot.pickerTitle", defaultValue: "Pet Character", table: "ChiefPet", bundle: .module)
    }
}
