import Foundation

/// Mac-side authorization policy for folders browsed from cmux on iOS.
public enum MobileArtifactFolderAccess: String, CaseIterable, Sendable, SettingCodable {
    /// Allow referenced directories and every canonical descendant.
    case subtree
    /// Preserve legacy access: immediate children for file operations and no
    /// recursive directory listing.
    case oneLevel
}
