public import Foundation

/// Answers "is there a sidebar file at exactly this path", spelled exactly this way.
///
/// `FileManager.fileExists` is not that question on the default macOS volume: APFS is
/// case-insensitive, so a lookup for `board.json` happily finds a file actually named
/// `board.JSON`. Every other part of the sidebar pipeline matches the extension exactly — the
/// classifier, the validator, the interpreter model — so a plain existence check hands them a file
/// they will then refuse, and the user gets a sidebar that resolves and renders nothing.
///
/// Comparing the requested spelling against the entry's real one is what makes the answer the same
/// on a case-sensitive volume and a case-insensitive one, which is the property that matters: a
/// sidebar that works on one Mac has to work on the next.
public struct CustomSidebarFileLookup {
    private let fileManager: FileManager

    /// Creates a lookup.
    ///
    /// - Parameter fileManager: The file system to ask. Injected so a test can drive one.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Whether a file exists at `url` whose on-disk name matches `url`'s last component exactly.
    ///
    /// Returns `false` for a directory, since no sidebar source is one.
    ///
    /// The on-disk spelling comes from the entry itself (`URLResourceKey.nameKey`), not from listing
    /// the enclosing directory. Both answer the same question — the entry's real name — but listing
    /// costs time proportional to the directory, and this runs on paths that probe several candidate
    /// extensions per resolution. In a 500-entry directory the listing form measured ~820µs per
    /// probe against ~3µs for the entry read.
    ///
    /// The cached value is dropped before each read. `URL` memoises resource values it has already
    /// fetched, and callers hold their candidate URLs across reloads, so without this a case-only
    /// rename would keep answering with the spelling from the first probe — the stale answer this
    /// type exists to prevent.
    ///
    /// - Parameter url: The candidate file.
    public func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        var probe = url
        probe.removeCachedResourceValue(forKey: .nameKey)
        guard let name = try? probe.resourceValues(forKeys: [.nameKey]).name else { return false }
        return name == probe.lastPathComponent
    }
}
