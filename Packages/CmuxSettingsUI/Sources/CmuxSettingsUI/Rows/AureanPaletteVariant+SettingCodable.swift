import CmuxAppearance
import CmuxSettings

/// Persists ``AureanPaletteVariant`` through `UserDefaults` and the cmux JSON config.
///
/// `AureanPaletteVariant` is a `String`-backed `RawRepresentable`, so it picks up
/// `SettingCodable`'s default implementation for free — this empty conformance just
/// opts it in so a `DefaultsKey<AureanPaletteVariant>` can back the settings picker.
extension AureanPaletteVariant: @retroactive SettingCodable {}
