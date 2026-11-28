

/// Settings for the palette's Settings scope and search. The source owns
/// the values and the write path; the palette only lists and previews.
@MainActor
public protocol PaletteSettingsSource: AnyObject {
    var rows: [PaletteSettingRow] { get }
    /// Destinations within Settings, opened through the app's Settings action.
    var navigationItems: [PaletteItem] { get }
    /// Shows `option` live without writing it; nil ends the preview.
    func preview(row: String, option: String?)
    /// Writes `option` ("on" or "off" for a toggle).
    func commit(row: String, option: String)
    /// Writes typed text (a custom input).
    func commit(row: String, text: String)
    /// Calls `onChange` when `rows` change outside a palette command (a write that landed or
    /// failed after its command returned). One observer: a later call replaces it.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void)
    /// Whether `reveal(row:)` opens anything: the App's source opens the Settings page; a source
    /// with no Settings page (a test's) offers no Show in Settings command.
    var revealsInSettings: Bool { get }
    /// Opens the Settings page at `row`: its section, the row focused (`openSettings setting:`).
    func reveal(row: String)
}

extension PaletteSettingsSource {
    public var navigationItems: [PaletteItem] { [] }

    public func observeChanges(_ onChange: @escaping @MainActor () -> Void) {}
    public var revealsInSettings: Bool { false }
    public func reveal(row: String) {}
}

public protocol PaletteRecentDirectorySource: AnyObject {
    /// Absolute paths, most recent first.
    var recentDirectories: [String] { get }
    func openDirectory(_ path: String)
}
