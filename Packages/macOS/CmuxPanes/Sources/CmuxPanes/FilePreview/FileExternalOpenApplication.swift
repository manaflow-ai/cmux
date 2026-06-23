public import Foundation

/// One application that can open a previewed file, as surfaced in the
/// "open externally" / "open with" menus.
///
/// `id` is the application bundle's symlink-resolved standardized path
/// (`URL.fileExternalOpenApplicationIdentity`), so two entries pointing at the
/// same on-disk app compare and deduplicate as equal.
public struct FileExternalOpenApplication: Identifiable, Equatable, Sendable {
    /// File-system URL of the application bundle.
    public let url: URL
    /// Human-readable application name shown in the menu.
    public let displayName: String
    /// Whether this is the system default application for the file's kind.
    public let isDefault: Bool

    /// Creates an application entry from its bundle URL, display name, and
    /// default-handler flag.
    public init(url: URL, displayName: String, isDefault: Bool) {
        self.url = url
        self.displayName = displayName
        self.isDefault = isDefault
    }

    public var id: String {
        url.fileExternalOpenApplicationIdentity
    }
}
