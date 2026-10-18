public import CmuxNextDesign

/// The Chief pet, off until it has a user setting (Settings, `chiefPet.enabled`).
public nonisolated struct ChiefPetTunables {
    public nonisolated init() {}

    public static let enabled = Tunable<Bool>.toggle(
        "chiefPet.enabled", .palette, "Chief pet",
        help: "A small Chief character that floats over every app: drag it anywhere, click it to open the Chief (prototype).",
        default: false, code: "ChiefPetTunables.enabled")

    public static var all: [TunableDescriptor] { [enabled.descriptor] }
}
