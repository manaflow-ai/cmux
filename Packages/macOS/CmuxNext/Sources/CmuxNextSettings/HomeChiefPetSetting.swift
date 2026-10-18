/// `home.chiefPetEnabled` in cmux.json: the Chief pet, a small Chief that floats over every app,
/// pops up agent events and takes a quick reply (CmuxNextFloating's `ChiefPetController`). Off by
/// default; Settings > Home, the palette's settings rows and `cmux settings set` turn it on.
public nonisolated struct HomeChiefPetSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "chiefPetEnabled"]
}
