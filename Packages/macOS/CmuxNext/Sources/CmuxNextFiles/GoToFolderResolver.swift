public import Foundation

/// Turns what a person types in Go to Folder (Cmd+Shift+G) into a place.
///
/// Accepts `~`, `~/x`, absolute paths, paths relative to the current
/// folder, `file://` URLs and quoted or backslash-escaped paths pasted from
/// a terminal. A path to a file goes to its folder with the file selected.
public struct GoToFolderResolver: Sendable {
    /// Where the typed path lands.
    public struct Destination: Sendable, Equatable {
        /// The folder to show.
        public let folder: URL
        /// The item to select in it (when the path named a file).
        public let select: URL?
    }

    private let home: URL
    private let fileExists: @Sendable (String) -> (exists: Bool, isFolder: Bool)

    /// Makes a resolver.
    /// - Parameters:
    ///   - home: What `~` means. Defaults to the person's home folder.
    ///   - fileExists: The file-system probe (a seam for tests).
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                fileExists: @escaping @Sendable (String) -> (exists: Bool, isFolder: Bool) = { path in
                    var isDir: ObjCBool = false
                    // SAFETY: `isDir` is a local that outlives the call; Foundation writes one ObjCBool through the
                    // pointer and keeps no reference to it after returning.
                    let exists = unsafe FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    return (exists, isDir.boolValue)
                }) {
        self.home = home
        self.fileExists = fileExists
    }

    /// The absolute URL `text` names, relative to `current`; nil for empty text.
    public func url(for text: String, relativeTo current: URL) -> URL? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count >= 2, let first = path.first, first == path.last, first == "'" || first == "\"" {
            path = String(path.dropFirst().dropLast())
        }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { return url.standardizedFileURL }
        if path.contains("\\") { path = Self.unescapeShell(path) }
        guard !path.isEmpty else { return nil }
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return current.appendingPathComponent(path).standardizedFileURL
    }

    /// Where `text` goes, or nil when nothing is there.
    public func resolve(_ text: String, relativeTo current: URL) -> Destination? {
        guard let url = url(for: text, relativeTo: current) else { return nil }
        let probe = fileExists(url.path)
        guard probe.exists else { return nil }
        if probe.isFolder { return Destination(folder: url, select: nil) }
        return Destination(folder: url.deletingLastPathComponent(), select: url)
    }

    /// Completions for the last path part of `text` from `names` (the
    /// children of the folder before it), case-insensitive, in name order.
    public func completions(for text: String, names: [String]) -> [String] {
        let prefix = (text.hasSuffix("/") ? "" : (text as NSString).lastPathComponent)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return names.filter {
            !$0.hasPrefix(".") || prefix.hasPrefix(".")
        }.filter {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).hasPrefix(prefix)
        }.sorted { FileNameSortKey($0) < FileNameSortKey($1) }
    }

    private static func unescapeShell(_ text: String) -> String {
        var out = ""
        var escaping = false
        for character in text {
            if escaping { out.append(character); escaping = false } else if character == "\\" { escaping = true } else { out.append(character) }
        }
        return out
    }
}
