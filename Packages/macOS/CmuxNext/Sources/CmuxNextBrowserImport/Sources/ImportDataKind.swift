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
    /// Kept for stored values from older builds; no longer produced.
    case needsChromiumImporter
    /// Firefox add-ons do not install in Chromium.
    case notChromeExtensions
    /// The source keeps this data encrypted or in iCloud (Safari passwords).
    case sourceEncrypted
    /// Passwords: cmux does not read password stores. The source's own
    /// export (or the Passwords app) moves them to a password manager.
    case exportFromSource
    /// Tor Browser: session data stays in Tor.
    case refusedForPrivacy
    /// A browser whose files use a private format cmux cannot read.
    case unknownFormat
}
