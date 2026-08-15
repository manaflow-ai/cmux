import CmuxFoundation

extension BrowserEngineDefaultChoice: SettingCodable {}

/// Settings-facing name for the shared default-engine preference.
///
/// The alias preserves the Settings API while ensuring renderer selection,
/// config decoding, and session persistence cannot drift to different cases.
/// `.auto` follows the system default browser; explicit values pin an engine.
public typealias BrowserEngineOption = BrowserEngineDefaultChoice
