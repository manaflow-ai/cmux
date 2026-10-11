public import Foundation

/// Chooses where a download is written.
public nonisolated enum DownloadDestination {
    /// File names are at most this many UTF-8 bytes (APFS), counted in the
    /// decomposed form Foundation writes (`fileSystemBytes`).
    public static let maxNameBytes = 255
    /// Candidates `uniqueURL` tries before it gives up.
    public static let collisionLimit = 10_000

    /// A file URL in `directory` for `suggestedFilename` that does not exist
    /// yet: `name.ext`, then `name (1).ext`, `name (2).ext`, ...; nil when
    /// all `collisionLimit` candidates are taken (the download fails, it
    /// never overwrites).
    ///
    /// The filename is reduced to its last path component and stripped of
    /// characters that are unsafe in Finder, so a server cannot write outside
    /// `directory`, and cut to `maxNameBytes` with its extension kept.
    /// `exists` defaults to `entryExists` (lstat: a dangling symlink is taken).
    public static func uniqueURL(
        in directory: URL,
        suggestedFilename: String,
        exists: (URL) -> Bool = entryExists
    ) -> URL? {
        let name = sanitizedFilename(suggestedFilename)
        for counter in 0..<collisionLimit {
            let candidate = directory.appending(path: numberedName(name, counter), directoryHint: .notDirectory)
            if !exists(candidate) { return candidate }
        }
        return nil
    }

    /// `name` with ` (n)` before its extension (none for 0), at most
    /// `maxNameBytes` bytes: the base is cut, the extension kept.
    public static func numberedName(_ name: String, _ counter: Int, suffix: String = "") -> String {
        let ext = (name as NSString).pathExtension
        // A long "extension" is part of the name, not a type to keep.
        let keepsExt = !ext.isEmpty && fileSystemBytes(ext) <= 32
        let base = keepsExt ? (name as NSString).deletingPathExtension : name
        let tail = (counter > 0 ? " (\(counter))" : "") + (keepsExt ? ".\(ext)" : "") + suffix
        return capped(base, bytes: maxNameBytes - fileSystemBytes(tail)) + tail
    }

    /// The bytes `text` takes as a file name: Foundation writes names
    /// decomposed (an "é" is 3 bytes there, not 2).
    static func fileSystemBytes(_ text: String) -> Int {
        text.decomposedStringWithCanonicalMapping.utf8.count
    }

    /// `text` cut to at most `bytes` file name bytes on a character boundary.
    static func capped(_ text: String, bytes: Int) -> String {
        guard fileSystemBytes(text) > bytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let size = fileSystemBytes(String(character))
            if used + size > bytes { break }
            result.append(character)
            used += size
        }
        return result
    }

    /// Whether anything is at `url`, a dangling symlink included (lstat;
    /// any error but "no such file" counts as taken).
    public static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 || errno != ENOENT
    }

    /// The last path component, without control or format characters
    /// (newlines, NUL, bidirectional overrides), `:` as `-`, without
    /// leading dots; "download" when nothing is left.
    public static func sanitizedFilename(_ raw: String) -> String {
        let lastComponent = raw.split(separator: "/").last.map(String.init) ?? ""
        let cleaned = lastComponent
            .replacingOccurrences(of: ":", with: "-")
            .filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }
            .trimmingCharacters(in: .whitespaces)
        let withoutLeadingDots = String(cleaned.drop { $0 == "." })
        return withoutLeadingDots.isEmpty ? "download" : withoutLeadingDots
    }

    /// The user's Downloads folder.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }
}
