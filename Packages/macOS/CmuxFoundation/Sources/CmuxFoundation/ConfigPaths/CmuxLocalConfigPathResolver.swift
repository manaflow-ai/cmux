public import Foundation

/// Pure path discovery for the project-local `cmux.json`. Walks up the directory
/// tree probing for `.cmux/cmux.json` then `cmux.json` at each level, and derives
/// the canonical/search-directory forms of a config path. Every transform here
/// touches only `String`/`NSString`/`URL` math plus `FileManager.fileExists`, so
/// the type is a small `Sendable` value carrying the `FileManager` it probes the
/// filesystem against (inject a scoped one in tests).
public struct CmuxLocalConfigPathResolver: Sendable {
    private let fileManager: FileManager

    /// Build a resolver that probes the filesystem through `fileManager`.
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Derive the search directory for a known local config `path`: the config
    /// file's directory, or its grandparent when the file lives in a `.cmux`
    /// subdirectory (so the search root is the project root, not `.cmux`).
    public func searchDirectory(forLocalConfigPath path: String) -> String {
        let configDirectory = (path as NSString).deletingLastPathComponent
        if (configDirectory as NSString).lastPathComponent == ".cmux" {
            return (configDirectory as NSString).deletingLastPathComponent
        }
        return configDirectory
    }

    /// Resolve `path` to its canonical form: a file URL with symlinks resolved
    /// and the path standardized.
    public func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The local config path to use when no existing `cmux.json` is found by
    /// walking up from `directory`: `<directory>/.cmux/cmux.json`.
    public func defaultLocalConfigPath(startingFrom directory: String) -> String {
        (((directory as NSString).appendingPathComponent(".cmux") as NSString)
            .appendingPathComponent("cmux.json"))
    }

    /// The local config path for `directory`: the nearest existing `cmux.json`
    /// found by walking up the tree, falling back to
    /// ``defaultLocalConfigPath(startingFrom:)``.
    public func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        findCmuxConfig(startingFrom: directory)
            ?? defaultLocalConfigPath(startingFrom: directory)
    }

    /// Walk up from `directory`, returning the first existing config path
    /// (`.cmux/cmux.json` preferred over `cmux.json` at each level), or `nil` if
    /// none exists up to the filesystem root.
    public func findCmuxConfig(startingFrom directory: String) -> String? {
        var current = directory
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json")
            ]
            for candidate in candidates where fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Walk up from `directory` collecting every existing config path (at most
    /// one per level, `.cmux/cmux.json` preferred over `cmux.json`), returned
    /// outermost-first (root before leaf) so callers can layer them.
    public func findCmuxConfigHierarchy(startingFrom directory: String) -> [String] {
        var current = directory
        var paths: [String] = []
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json")
            ]
            if let candidate = candidates.first(where: { fileManager.fileExists(atPath: $0) }) {
                paths.append(candidate)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return paths.reversed()
    }
}
