import Foundation

/// The on-disk shape of `~/.config/cmux/extensions.json`: a schema version
/// plus every installed/linked extension record. This file is the source of
/// truth for what is installed; the checkouts under
/// `~/.local/state/cmux/extensions/` are re-materializable from it.
public struct DockExtensionsLockFile: Codable, Equatable, Sendable {
    /// The lockfile schema version this build writes.
    public static let currentSchemaVersion = 1

    /// Schema version of the decoded file.
    public var schemaVersion: Int

    /// Every installed or linked extension, in install order.
    public var extensions: [DockExtensionInstallRecord]

    /// An empty lockfile at the current schema version.
    public static var empty: DockExtensionsLockFile {
        DockExtensionsLockFile(schemaVersion: currentSchemaVersion, extensions: [])
    }

    /// Creates a lockfile value.
    public init(schemaVersion: Int = DockExtensionsLockFile.currentSchemaVersion,
                extensions: [DockExtensionInstallRecord] = []) {
        self.schemaVersion = schemaVersion
        self.extensions = extensions
    }

    /// The record with the given extension id, if present.
    public func record(id: String) -> DockExtensionInstallRecord? {
        extensions.first { $0.id == id }
    }
}
