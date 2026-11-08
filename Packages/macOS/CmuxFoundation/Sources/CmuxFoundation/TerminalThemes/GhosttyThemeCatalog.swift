public import Foundation

/// One Ghostty theme file found on disk.
public struct GhosttyThemeCatalogEntry: Equatable, Sendable {
    /// The theme's name, which is its file name.
    public let name: String
    /// The theme file.
    public let url: URL

    /// Creates an entry.
    /// - Parameters:
    ///   - name: The name `theme = <name>` refers to.
    ///   - url: The theme file.
    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// Lists the Ghostty theme files in a set of directories.
///
/// ```swift
/// let names = GhosttyThemeCatalog(directories: GhosttyThemeDirectories(...).urls)
///     .entries()
///     .map(\.name)
/// ```
public struct GhosttyThemeCatalog {
    private let directories: [URL]
    private let fileManager: FileManager

    /// Creates a catalog over `directories`.
    /// - Parameters:
    ///   - directories: Searched in order; see ``GhosttyThemeDirectories``.
    ///   - fileManager: Injected for tests; defaults to `FileManager.default`.
    public init(directories: [URL], fileManager: FileManager = .default) {
        self.directories = directories
        self.fileManager = fileManager
    }

    /// Theme files sorted by name. When two directories hold the same name
    /// (ignoring case and diacritics), the earlier directory wins.
    public func entries() -> [GhosttyThemeCatalogEntry] {
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
