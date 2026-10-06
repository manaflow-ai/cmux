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
    }
    public let kind: Kind
    /// Dotted key path of the offending entry.
    public let path: String
    public let message: String
    public init(kind: Kind, path: String, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }
    public var description: String { "\(kind.rawValue) \(path): \(message)" }
}
