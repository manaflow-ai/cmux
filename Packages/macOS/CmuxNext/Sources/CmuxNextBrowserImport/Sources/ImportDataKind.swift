import Foundation

/// One kind of data a profile can hold.
public enum ImportDataKind: String, Sendable, Codable, CaseIterable, Hashable {
    case bookmarks
    case history
    case openTabs
    case extensions
    case passwords
    case cookies
}

/// Whether one kind of data can be imported from one profile.
public enum DataAvailability: Sendable, Hashable, Codable {
    /// The file is there and readable.
    case available
    /// macOS privacy protection blocks the file until the user gives cmux
    /// Full Disk Access (Safari).
    case needsFullDiskAccess
    /// The data exists but this build cannot move it (see `UnsupportedReason`).
    case unsupported(UnsupportedReason)
    /// The profile has none.
    case absent

    public var isImportable: Bool { self == .available }
}

/// Why present data cannot be imported.
public enum UnsupportedReason: String, Sendable, Codable {
    /// Passwords and cookies are encrypted with the source browser's own key
    /// and must be written into Chromium's encrypted stores; CEF does not
    /// expose Chromium's importer yet.
    case needsChromiumImporter
    /// Firefox add-ons do not install in Chromium.
    case notChromeExtensions
    /// The source keeps this data encrypted or in iCloud (Safari passwords).
    case sourceEncrypted
}
