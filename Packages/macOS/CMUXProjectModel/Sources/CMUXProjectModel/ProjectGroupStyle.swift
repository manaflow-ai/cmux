import Foundation

/// How a ``ProjectGroup`` is materialized on disk.
///
/// The visual UI collapses ``logical``, ``folderRef``, ``variant``, and
/// ``synchronized`` into a single tree node by default; the style is exposed
/// to power-user / "Raw" inspectors and to writers that need to round-trip
/// the underlying object correctly.
public enum ProjectGroupStyle: String, Sendable, Hashable, Codable {
    /// Classic Xcode "yellow folder" (`PBXGroup`). The group does not have to
    /// correspond to a directory on disk.
    case logical

    /// Xcode "blue folder reference". The group is a thin shell around a real
    /// on-disk directory; children are derived from the directory contents at
    /// open time and cannot be reordered.
    case folderRef

    /// Localized variant group (`PBXVariantGroup`). Children are the
    /// locale-specific siblings of the same logical resource (e.g.
    /// `Main.storyboard/en.lproj`, `Main.storyboard/ja.lproj`).
    case variant

    /// Xcode 16+ file-system-synchronized root group
    /// (`PBXFileSystemSynchronizedRootGroup`). Membership is derived by
    /// walking the filesystem at open time and applying per-target exception
    /// sets.
    case synchronized
}
