import CmuxNextDesign

/// The Chief pet, off until it has a user setting (Settings, `chiefPet.enabled`).
nonisolated enum ChiefPetTunables {
    static let enabled = Tunable<Bool>.toggle(
        "chiefPet.enabled", .palette, "Chief pet",
        help: "A small Chief character that floats over every app: drag it anywhere, click it to open the Chief (prototype).",
        default: false, code: "ChiefPetTunables.enabled")

    static var all: [TunableDescriptor] { [enabled.descriptor] }
}
