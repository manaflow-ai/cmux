public import Foundation

/// Chooses where a download is written.
public nonisolated enum DownloadDestination {
    /// A file URL in `directory` for `suggestedFilename` that does not exist
    /// yet: `name.ext`, then `name (1).ext`, `name (2).ext`, ...
    ///
    /// The filename is reduced to its last path component and stripped of
    /// characters that are unsafe in Finder, so a server cannot write outside
    /// `directory`.
    public static func uniqueURL(
        in directory: URL,
        suggestedFilename: String,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> URL? {
        let name = sanitizedFilename(suggestedFilename)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var candidate = directory.appending(path: name, directoryHint: .notDirectory)
        var counter = 1
        while exists(candidate), counter < 10_000 {
            let numbered = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appending(path: numbered, directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
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
