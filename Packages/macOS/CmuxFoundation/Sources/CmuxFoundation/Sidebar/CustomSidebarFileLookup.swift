public import Foundation

/// Answers "is there a sidebar file at exactly this path", spelled exactly this way.
///
/// `FileManager.fileExists` is not that question on the default macOS volume: APFS is
/// case-insensitive, so a lookup for `board.json` happily finds a file actually named
/// `board.JSON`. Every other part of the sidebar pipeline matches the extension exactly — the
/// classifier, the validator, the interpreter model — so a plain existence check hands them a file
/// they will then refuse, and the user gets a sidebar that resolves and renders nothing.
///
/// Comparing against the directory's real entries is what makes the answer the same on a
/// case-sensitive volume and a case-insensitive one, which is the property that matters: a sidebar
/// that works on one Mac has to work on the next.
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
    /// - Parameter url: The candidate file.
    public func exists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        guard let entries = try? fileManager.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path
        ) else { return false }
        return entries.contains(url.lastPathComponent)
    }
}
