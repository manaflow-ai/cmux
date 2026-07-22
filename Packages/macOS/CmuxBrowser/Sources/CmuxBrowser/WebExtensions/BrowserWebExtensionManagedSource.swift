import Foundation

/// Identifies the persisted, re-openable source of an installed extension.
public enum BrowserWebExtensionManagedSource: Codable, Equatable, Sendable {
    /// An unpacked directory copied into the profile-managed directory.
    case directory(filename: String, digest: String)

    /// An exact-digest catalog archive copied into the profile-managed directory.
    case catalogArchive(filename: String, digest: String, catalogID: String)

    /// A signed Safari WebExtension inside a separately installed application.
    case safariApp(BrowserWebExtensionAppExtensionReference)
}
