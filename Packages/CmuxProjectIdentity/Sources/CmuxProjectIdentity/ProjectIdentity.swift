public import Foundation

/// The resolved visual identity of a project shown in the sidebar.
///
/// All fields are value types so the identity can cross actor boundaries.
/// ``iconPNGData`` is raw PNG bytes (not an `NSImage`) precisely so the value
/// stays `Sendable`; the UI layer decodes it on the main actor.
public struct ProjectIdentity: Sendable, Equatable {
    /// Display name for the project (defaults to the project root folder name).
    public let projectName: String
    /// PNG bytes of the app icon, or `nil` when no `AppIcon` asset was found.
    public let iconPNGData: Data?
    /// Dominant color of the icon as a `#RRGGBB` hex string, or `nil` if unknown.
    public let dominantColorHex: String?
    /// 1–2 letter fallback drawn when ``iconPNGData`` is `nil`.
    public let monogram: String

    /// Creates a resolved project identity.
    public init(projectName: String, iconPNGData: Data?, dominantColorHex: String?, monogram: String) {
        self.projectName = projectName
        self.iconPNGData = iconPNGData
        self.dominantColorHex = dominantColorHex
        self.monogram = monogram
    }
}
