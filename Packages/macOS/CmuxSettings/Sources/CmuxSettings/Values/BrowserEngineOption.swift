import CmuxFoundation

extension BrowserEngineKind: SettingCodable {}

/// Settings-facing name for the shared browser engine value.
///
/// The alias preserves the Settings API while ensuring renderer selection,
/// config decoding, and session persistence cannot drift to different cases.
public typealias BrowserEngineOption = BrowserEngineKind
