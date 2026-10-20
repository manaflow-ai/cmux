public import AppKit

/// The Chief pet's character: the Chief Dock's nine pixel mascots (#21194, its `ChiefMascot`
/// ids), bundled at 256 px wide. Orb is the dock's default too.
public enum ChiefPetMascot: String, CaseIterable, Sendable {
    case orb
    case orbSpark = "orb-spark"
    case orbHood = "orb-hood"
    case machine
    case machineCyan = "machine-cyan"
    case machineBlue = "machine-blue"
    case moon
    case moonBlue = "moon-blue"
    case fox

    public static let initial = ChiefPetMascot.orb

    /// The bundled PNG's name.
    var resource: String {
        "ChiefMascot" + rawValue.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    public var image: NSImage? { Bundle.module.image(forResource: resource) }
}
