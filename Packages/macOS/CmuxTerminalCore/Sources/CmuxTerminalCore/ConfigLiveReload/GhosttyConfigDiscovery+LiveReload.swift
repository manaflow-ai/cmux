public import Foundation
import CmuxFoundation

extension GhosttyConfigDiscovery {
    /// Returns every top-level Ghostty config file cmux could load, whether or
    /// not it exists yet, for the config file watcher.
    ///
    /// This is a superset of
    /// ``loadedGhosttyConfigScanPaths(currentBundleIdentifier:appSupportDirectory:)``:
    /// that list drops a legacy `config` or an empty cmux config file, but
    /// writing to one of those can change which file cmux loads, so the watcher
    /// still observes it.
    ///
    /// - Parameters:
    ///   - currentBundleIdentifier: The running app's bundle identifier.
    ///   - appSupportDirectory: The user's Application Support directory.
    /// - Returns: Absolute, de-duplicated paths.
    public func liveReloadTopLevelPaths(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL?
    ) -> [String] {
        var paths = loadedGhosttyConfigScanPaths(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
        if let appSupportDirectory {
            let nativeDirectory = appSupportDirectory
                .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
            var cmuxDirectories = [
                appSupportDirectory.appendingPathComponent(
                    Self.releaseBundleIdentifier,
                    isDirectory: true
                ),
            ]
            if let currentBundleIdentifier, !currentBundleIdentifier.isEmpty {
                cmuxDirectories.append(
                    CmuxGhosttyConfigPathResolver().configDirectoryURL(
                        currentBundleIdentifier: currentBundleIdentifier,
                        appSupportDirectory: appSupportDirectory
                    )
                )
            }
            for directory in [nativeDirectory] + cmuxDirectories {
                paths.append(directory.appendingPathComponent("config.ghostty", isDirectory: false).path)
                paths.append(directory.appendingPathComponent("config", isDirectory: false).path)
            }
        }
        return Self.uniqueStandardizedPaths(paths)
    }

    /// Reads the config files reachable from `topLevelPaths` and returns what
    /// the config file watcher needs: the paths to observe and their contents.
    ///
    /// Follows `config-file` includes (relative to the including file, with
    /// the optional `?` prefix) and adds user theme files named by `theme`
    /// directives: an absolute theme path, or `<configHome>/ghostty/themes/<name>`
    /// for each side of a `light:…,dark:…` pair. Themes bundled with the app do
    /// not change at runtime and are not watched. Symlinked files also watch
    /// their resolved target, so dotfile setups that replace the target file
    /// are noticed.
    ///
    /// Performs file I/O through the injected ``GhosttyConfigFileReading``;
    /// call it off the main thread.
    ///
    /// - Parameters:
    ///   - topLevelPaths: The top-level config candidates, typically
    ///     ``liveReloadTopLevelPaths(currentBundleIdentifier:appSupportDirectory:)``.
    ///   - configHomeDirectory: The XDG config home (`$XDG_CONFIG_HOME`, or
    ///     `~/.config`) whose `ghostty/themes` directory holds user themes.
    ///   - resolvesSymlinks: Whether to add each file's resolved symlink
    ///     target. Tests that use in-memory readers pass `false`.
    /// - Returns: The watch paths and file contents.
    public func liveReloadSnapshot(
        topLevelPaths: [String],
        configHomeDirectory: String,
        resolvesSymlinks: Bool = true
    ) -> GhosttyConfigLiveReloadSnapshot {
        var watchedPaths: [String] = []
        var watchedPathSet = Set<String>()
        var contentsByPath: [String: String] = [:]
        var themeValues: [String] = []

        func watch(_ rawPath: String) -> String? {
            let path = Self.standardizedPath(rawPath)
            guard !path.isEmpty else { return nil }
            if watchedPathSet.insert(path).inserted {
                watchedPaths.append(path)
            }
            if resolvesSymlinks {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                if resolved != path, watchedPathSet.insert(resolved).inserted {
                    watchedPaths.append(resolved)
                }
            }
            return path
        }

        func read(_ path: String, recursiveConfigPaths: inout [String]) {
            guard contentsByPath[path] == nil,
                  let contents = fileReader.contents(atPath: path) else { return }
            contentsByPath[path] = contents
            let parentDirectory = (path as NSString).deletingLastPathComponent
            for line in contents.components(separatedBy: .newlines) {
                guard let entry = Self.parsedConfigEntry(from: line),
                      let value = entry.value else { continue }
                switch entry.key {
                case "config-file":
                    Self.applyConfigFileDirective(
                        value,
                        valueWasQuoted: entry.valueWasQuoted,
                        parentDir: parentDirectory,
                        recursiveConfigPaths: &recursiveConfigPaths
                    )
                case "theme":
                    themeValues.append(value)
                default:
                    continue
                }
            }
        }

        var recursiveConfigPaths: [String] = []
        for topLevelPath in topLevelPaths {
            guard let path = watch(topLevelPath) else { continue }
            read(path, recursiveConfigPaths: &recursiveConfigPaths)
        }
        var visitedIncludes = Set<String>()
        while !recursiveConfigPaths.isEmpty {
            let include = recursiveConfigPaths.removeFirst()
            guard let path = watch(include),
                  visitedIncludes.insert(path).inserted else { continue }
            read(path, recursiveConfigPaths: &recursiveConfigPaths)
        }

        let userThemesDirectory = (Self.standardizedPath(configHomeDirectory) as NSString)
            .appendingPathComponent("ghostty/themes")
        for themeValue in themeValues {
            for themePath in Self.userThemePaths(
                forThemeValue: themeValue,
                userThemesDirectory: userThemesDirectory
            ) {
                guard let path = watch(themePath) else { continue }
                if contentsByPath[path] == nil,
                   let contents = fileReader.contents(atPath: path) {
                    contentsByPath[path] = contents
                }
            }
        }

        return GhosttyConfigLiveReloadSnapshot(
            watchedPaths: watchedPaths,
            contentsByPath: contentsByPath
        )
    }

    /// The user-owned theme files a `theme` value can load: absolute paths as
    /// written, and bare names under the user themes directory.
    static func userThemePaths(
        forThemeValue themeValue: String,
        userThemesDirectory: String
    ) -> [String] {
        var names: [String] = []
        for scheme in [GhosttyConfig.ColorSchemePreference.light, .dark] {
            guard let name = GhosttyConfig.appliedThemeName(
                from: themeValue,
                preferredColorScheme: scheme
            ), !names.contains(name) else { continue }
            names.append(name)
        }
        return names.map { name in
            let expanded = NSString(string: name).expandingTildeInPath
            if (expanded as NSString).isAbsolutePath {
                return expanded
            }
            return (userThemesDirectory as NSString).appendingPathComponent(name)
        }
    }

    private static func standardizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (NSString(string: trimmed).expandingTildeInPath as NSString).standardizingPath
    }

    private static func uniqueStandardizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let standardized = standardizedPath(path)
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { continue }
            result.append(standardized)
        }
        return result
    }
}
