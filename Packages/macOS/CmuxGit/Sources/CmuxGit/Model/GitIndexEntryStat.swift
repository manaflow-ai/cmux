import Foundation

/// One parsed entry from a git `index` file: the path plus the cached stat
/// fields git uses to decide whether the working-tree file changed.
///
/// The fields mirror the on-disk index entry layout (big-endian), narrowed to
/// what dirty-detection needs. Used internally by ``GitMetadataService`` index
/// parsing; surfaced for test inspection.
struct GitIndexEntryStat: Sendable {
    /// Repository-relative path of the tracked entry.
    let path: String

    /// The git mode word (e.g. `0o100644`, `0o100755`, `0o120000`, or the
    /// `0o160000` gitlink mode for a submodule).
    let mode: UInt32

    /// The 40-hex-char object ID (blob SHA, or the recorded submodule commit).
    let objectID: String

    /// Cached `mtime` seconds, truncated to 32 bits as git stores it.
    let mtimeSeconds: UInt32

    /// Cached `mtime` nanoseconds, truncated to 32 bits as git stores it.
    let mtimeNanoseconds: UInt32

    /// Cached file size, truncated to 32 bits as git stores it.
    let size: UInt32
}
