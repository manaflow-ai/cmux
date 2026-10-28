public import AppKit

/// The Chief pet's character: the Chief Dock's nine pixel mascots (#21194, its `ChiefMascot`
/// ids), bundled at 256 px wide, and Mochi, the first animated avatar set. Orb is the dock's default too.
public nonisolated enum ChiefPetMascot: String, CaseIterable, Sendable {
    case orb
    case orbSpark = "orb-spark"
    case orbHood = "orb-hood"
    case machine
    case machineCyan = "machine-cyan"
    case machineBlue = "machine-blue"
    case moon
    case moonBlue = "moon-blue"
    case fox
    /// The first animated set (`cmux-avatar/1`, webviews avatars/sets/mochi); still here, its idle frame.
    case mochi

    public static let initial = ChiefPetMascot.orb

    /// The bundled PNG's name.
    var resource: String {
        "ChiefMascot" + rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    public var image: NSImage? { Bundle.module.image(forResource: resource) }

    /// The character as a Chief avatar: whole, centered on a transparent square with room
    /// around it (`…Avatar.png`), so a round avatar (the Home header and list, New Message)
    /// shows all of it and no disc behind it.
    public var avatarURL: URL? { Bundle.module.url(forResource: resource + "Avatar", withExtension: "png") }

    /// The character picker's label beside Show Chief Pet (the Chief Settings popover).
    public static var pickerTitle: String {
        String(localized: "chiefPet.mascot.pickerTitle", defaultValue: "Pet Character", table: "ChiefPet", bundle: .module)
    }
}
