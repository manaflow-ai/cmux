public import Foundation

/// One Ghostty theme file found on disk.
public struct GhosttyThemeCatalogEntry: Equatable, Sendable {
    /// The theme's name, which is its file name.
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Lists Ghostty theme files the way Ghostty resolves `theme = <name>`.
public enum GhosttyThemeCatalog {
    /// Theme files in `directories`, sorted by name. When two directories hold
    /// the same name (ignoring case and diacritics), the earlier directory wins.
    public static func entries(
        in directories: [URL],
        fileManager: FileManager = .default
    ) -> [GhosttyThemeCatalogEntry] {
        var seen: Set<String> = []
        var entries: [GhosttyThemeCatalogEntry] = []
        for directoryURL in directories {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard values?.isDirectory != true else { continue }
                guard values?.isRegularFile == true || values?.isRegularFile == nil else { continue }
                let name = url.lastPathComponent
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.insert(folded).inserted {
                    entries.append(GhosttyThemeCatalogEntry(name: name, url: url))
                }
            }
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
