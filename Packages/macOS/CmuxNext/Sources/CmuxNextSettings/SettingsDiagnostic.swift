import Foundation

/// A problem found while reading cmux.json. Loading never fails on a bad
/// entry: the entry is skipped and reported here.
public struct SettingsDiagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable {
        /// The file is not valid JSONC. Nothing was applied from it.
        case unreadableFile
        case invalidValue
        case unknownAction
        case unknownMetric
        /// A chord whose first key has neither Command nor Control.
        case unsupportedChord
        /// Two actions claim the same shortcut in the same context.
        case shortcutConflict
        /// The file sets a key an MDM profile or the team policy manages; the file's value is ignored.
        case managedOverride
        /// An MDM forced value and the team policy's enforced value differ; the MDM value applies (decision E2).
        case managedConflict
        /// The key belongs to a removed feature; its value is ignored.
        case removedSetting
        /// A value applies changed, not as written: a theme file's text color raised to 4.5:1
        /// contrast (`ThemeFileOverlay`). Settings says so at the row; no toast.
        case correctedValue
        /// The active theme file sets the key, over cmux-next.json's value (`ThemeFileOverlay`).
        /// Settings says so at the row; no toast.
        case setByThemeFile
    }
    public let kind: Kind
    /// Dotted key path of the offending entry.
    public let path: String
    public let message: String
    /// The file the value came from when it is not cmux-next.json (`themes/<name>.json`), else nil.
    public let file: String?
    /// That file's value as compact JSON, when `file` is set.
    public let value: String?
    public init(kind: Kind, path: String, message: String, file: String? = nil, value: String? = nil) {
        self.kind = kind
        self.path = path
        self.message = message
        self.file = file
        self.value = value
    }
    /// The message as a Settings row shows it: a theme file's entry names that file first.
    public var pageMessage: String { file.map { "\($0): \(message)" } ?? message }
    public var description: String { "\(kind.rawValue) \(file.map { "\($0): " } ?? "")\(path): \(message)" }
}
