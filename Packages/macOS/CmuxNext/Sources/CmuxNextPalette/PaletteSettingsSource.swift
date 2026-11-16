

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
    /// Calls `onChange` when `rows` change outside a palette command (a write that landed or
    /// failed after its command returned). One observer: a later call replaces it.
    func observeChanges(_ onChange: @escaping @MainActor () -> Void)
}

/// One value for one setting, by its option id (`PaletteSettingOption.id`: the value's compact JSON
/// text, or "reset" for the default): what the font picker previews and writes together.
public struct PaletteSettingEdit: Equatable, Sendable {
    public var row: String
    public var option: String

    public init(row: String, option: String) {
        self.row = row
        self.option = option
    }

    /// A number's option id: its JSON text ("13", "1.25").
    public init(row: String, number: Double) {
        self.row = row
        self.option = number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}

/// The font picker's preview and write of several settings at once.
@MainActor
public protocol PaletteSettingsBatchSource: PaletteSettingsSource {
    /// Shows every edit live together, without writing; empty ends the preview. `terminal`: the
    /// terminal shows the terminal font's edits too (the Settings window's slider does not ask).
    func preview(_ edits: [PaletteSettingEdit], terminal: Bool)
    /// Writes every edit in one write.
    func commit(_ edits: [PaletteSettingEdit])
}

extension PaletteSettingsSource {
    public func observeChanges(_ onChange: @escaping @MainActor () -> Void) {}

    /// The batch source's preview, else each edit's own (the last one shows).
    func previewEdits(_ edits: [PaletteSettingEdit]) {
        if let batch = self as? any PaletteSettingsBatchSource { return batch.preview(edits, terminal: true) }
        guard let last = edits.last else { return }
        preview(row: last.row, option: last.option)
    }

    /// The batch source's write, else each edit's own.
    func commitEdits(_ edits: [PaletteSettingEdit]) {
        if let batch = self as? any PaletteSettingsBatchSource { return batch.commit(edits) }
        for edit in edits { commit(row: edit.row, option: edit.option) }
    }

    /// Ends any preview.
    func endPreview(row: String) { preview(row: row, option: nil) }
}

public protocol PaletteRecentDirectorySource: AnyObject {
    /// Absolute paths, most recent first.
    var recentDirectories: [String] { get }
    func openDirectory(_ path: String)
}
