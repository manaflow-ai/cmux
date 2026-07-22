public import Foundation

/// Identifies the persisted, re-openable source of an installed extension.
public enum BrowserWebExtensionManagedSource: Codable, Equatable, Sendable {
    /// An unpacked directory copied into the profile-managed directory.
    case directory(filename: String, digest: String)

    /// An exact-digest catalog archive copied into the profile-managed directory.
    case catalogArchive(filename: String, digest: String, catalogID: String)

    /// A signed Safari WebExtension inside a separately installed application.
    case safariApp(BrowserWebExtensionAppExtensionReference)
}

/// Source-scoped durable identities prevent unrelated install channels from
/// replacing one another when filenames or bundle identifiers happen to match.
public enum BrowserWebExtensionManagementIdentity {
    public static let diskPrefix = "disk:"
    public static let catalogPrefix = "catalog:"
    public static let safariAppPrefix = "safari:"

    public static func disk(id: UUID = UUID()) -> String {
        diskPrefix + id.uuidString.lowercased()
    }

    public static func catalog(id: String) -> String {
        catalogPrefix + id
    }

    public static func safariApp(bundleIdentifier: String) -> String {
        safariAppPrefix + bundleIdentifier
    }
}
