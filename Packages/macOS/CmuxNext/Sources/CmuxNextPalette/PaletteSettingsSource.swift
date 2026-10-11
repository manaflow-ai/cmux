

/// Settings for the palette's Settings scope and search. The source owns
/// the values and the write path; the palette only lists and previews.
@MainActor
public protocol PaletteSettingsSource: AnyObject {
    var rows: [PaletteSettingRow] { get }
    /// Shows `option` live without writing it; nil ends the preview.
    func preview(row: String, option: String?)
    /// Writes `option` ("on" or "off" for a toggle).
    func commit(row: String, option: String)
    /// Writes typed text (a custom input).
    func commit(row: String, text: String)
}

public protocol PaletteRecentDirectorySource: AnyObject {
    /// Absolute paths, most recent first.
    var recentDirectories: [String] { get }
    func openDirectory(_ path: String)
}
