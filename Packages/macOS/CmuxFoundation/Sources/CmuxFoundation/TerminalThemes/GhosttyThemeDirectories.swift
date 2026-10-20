public import Foundation

/// The directories cmux searches for Ghostty theme files, in lookup order.
///
/// `cmux themes` and the Settings theme gallery both list themes from this
/// one list, so they always offer the same names. Only directories that exist
/// are returned, each once.
///
/// ```swift
/// let directories = GhosttyThemeDirectories(
///     environment: ProcessInfo.processInfo.environment,
///     bundledThemeDirectories: [Bundle.main.resourceURL!.appendingPathComponent("ghostty/themes")]
/// ).urls
/// ```
public struct GhosttyThemeDirectories {
    private let environment: [String: String]
    private let bundledThemeDirectories: [URL]
    private let fileManager: FileManager

    /// Creates the resolver.
    /// - Parameters:
    ///   - environment: The process environment; reads `GHOSTTY_RESOURCES_DIR`,
    ///     `XDG_DATA_DIRS`, `HOME` and `CFFIXED_USER_HOME`.
    ///   - bundledThemeDirectories: Theme directories inside the running cmux
    ///     bundle or checkout, searched right after `GHOSTTY_RESOURCES_DIR`.
    ///   - fileManager: Injected for tests; defaults to `FileManager.default`.
    public init(
        environment: [String: String],
        bundledThemeDirectories: [URL],
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.bundledThemeDirectories = bundledThemeDirectories
        self.fileManager = fileManager
    }

    /// The existing theme directories, most preferred first.
    public var urls: [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        if let resourcesDir = environment["GHOSTTY_RESOURCES_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resourcesDir.isEmpty {
            append(URL(fileURLWithPath: resourcesDir, isDirectory: true).appendingPathComponent("themes", isDirectory: true))
        }
        bundledThemeDirectories.forEach(append)
        if let xdgDataDirs = environment["XDG_DATA_DIRS"] {
            for dataDir in xdgDataDirs.split(separator: ":").map(String.init) where !dataDir.isEmpty {
                append(homeExpandedURL(dataDir).appendingPathComponent("ghostty/themes", isDirectory: true))
            }
        }
        append(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes", isDirectory: true))
        append(homeExpandedURL("~/.config/ghostty/themes"))
        for appSupportDirectory in CmuxApplicationSupportDirectories(
            environment: environment,
            fileManager: fileManager
        ).userDirectories {
            append(
                appSupportDirectory
                    .appendingPathComponent(CmuxGhosttyConfigPathResolver.releaseBundleIdentifier, isDirectory: true)
                    .appendingPathComponent("themes", isDirectory: true)
            )
        }
        append(homeExpandedURL("~/Library/Application Support/com.mitchellh.ghostty/themes"))
        return urls
    }

    private func homeExpandedURL(_ rawPath: String) -> URL {
        if rawPath.hasPrefix("~/"),
           let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(rawPath.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath, isDirectory: true)
    }
}
