public import Foundation

/// A candidate application that can open a given file, used to populate the
/// "Open With" surfaces. Identity is the resolved on-disk path of the
/// application bundle, so duplicate listings (e.g. the default app also
/// appearing in the full application list) collapse to one entry.
public struct FileExternalOpenApplication: Identifiable, Equatable, Sendable {
    /// Location of the application bundle that would open the file.
    public let url: URL
    /// Human-readable name shown in the menu (already stripped of `.app`).
    public let displayName: String
    /// Whether this is the system-default application for the file.
    public let isDefault: Bool

    public init(url: URL, displayName: String, isDefault: Bool) {
        self.url = url
        self.displayName = displayName
        self.isDefault = isDefault
    }

    public var id: String {
        FileExternalOpenApplicationResolver.applicationIdentity(for: url)
    }
}
