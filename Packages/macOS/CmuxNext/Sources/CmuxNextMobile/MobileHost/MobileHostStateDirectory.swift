import CmuxNextCompat
public import Foundation

/// The iPhone host's state folder in the app's Application Support folder: device id,
/// paired phones, removal marker and the host's own files.
///
/// Builds up to the production rename kept it under `cnx-host`; the first resolve moves it
/// to `cmux-mobile-host` (unless that exists), so paired phones stay paired.
public struct MobileHostStateDirectory: Sendable {
    public static let name = "cmux-mobile-host"
    public static let legacyName = "cnx-host"

    /// The per-bundle Application Support folder that holds the state folder.
    public let parent: URL

    public init(parent: URL) {
        self.parent = parent
    }

    /// The state folder, after moving a pre-rename one into place.
    public func resolve() -> URL {
        let current = parent.appendingPathComponent(Self.name, isDirectory: true)
        let legacy = parent.appendingPathComponent(Self.legacyName, isDirectory: true)
        if !FileManager.checked.fileExists(atPath: current.path), FileManager.checked.fileExists(atPath: legacy.path) {
            try? FileManager.checked.moveItem(at: legacy, to: current)
        }
        return current
    }
}
