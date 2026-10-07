public import Foundation

/// Reads Firefox's `profiles.ini`: `[ProfileN]` sections with `Name`,
/// `Path` and `IsRelative`. The profile marked `Default=1` comes first.
public struct FirefoxProfileList {
    private let fileManager: FileManager

    /// Creates a reader with the filesystem used to discover Firefox profiles.
    ///
    /// - Parameter fileManager: Filesystem access for discovery.
    public init(fileManager: FileManager = FileManager()) {
        self.fileManager = fileManager
    }

    public struct Entry: Sendable, Equatable {
        public var directoryName: String
        public var displayName: String
        public var path: URL
    }

    public func entries(in firefoxDirectory: URL) -> [Entry] {
        let ini = firefoxDirectory.appending(path: "profiles.ini")
        guard let data = fileManager.contents(atPath: ini.path), let text = String(data: data, encoding: .utf8) else { return folderProfiles(in: firefoxDirectory) }
        return parse(text, base: firefoxDirectory)
            .filter { fileManager.fileExists(atPath: $0.path.path) }
    }

    /// No `profiles.ini` (Tor Browser keeps `profile.default` beside its
    /// data): folders with a `prefs.js`, directly or under `Profiles/`.
    func folderProfiles(in base: URL) -> [Entry] {
        let manager = fileManager
        var entries: [Entry] = []
        for prefix in ["", "Profiles/"] {
            let parent = prefix.isEmpty ? base : base.appending(path: prefix, directoryHint: .isDirectory)
            let names = ((try? manager.contentsOfDirectory(atPath: parent.path)) ?? []).sorted()
            for name in names where manager.fileExists(atPath: parent.appending(path: name).appending(path: "prefs.js").path) {
                entries.append(Entry(directoryName: prefix + name, displayName: name, path: parent.appending(path: name, directoryHint: .isDirectory)))
            }
        }
        return entries
    }

    func parse(_ text: String, base: URL) -> [Entry] {
        var sections: [[String: String]] = []
        var current: [String: String]?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let current { sections.append(current) }
                current = line.hasPrefix("[Profile") ? [:] : nil
                continue
            }
            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            current?[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        if let current { sections.append(current) }
        let profiles = sections.compactMap { section -> (Entry, Bool)? in
            guard let path = section["Path"], !path.isEmpty else { return nil }
            let relative = section["IsRelative"] != "0"
            let url = relative ? base.appending(path: path, directoryHint: .isDirectory) : URL(fileURLWithPath: path, isDirectory: true)
            let name = section["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
            return (Entry(directoryName: path, displayName: name, path: url), section["Default"] == "1")
        }
        return profiles.filter(\.1).map(\.0) + profiles.filter { !$0.1 }.map(\.0)
    }
}
