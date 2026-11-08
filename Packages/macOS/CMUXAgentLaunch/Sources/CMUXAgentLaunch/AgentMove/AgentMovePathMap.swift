import Foundation

/// Maps absolute paths from the source machine to the destination machine.
///
/// When the destination exposes the same home directory at the same absolute
/// path (the same account on another Mac, or a Linux bind mount of the home at
/// the Mac's path), nothing is rewritten: the transcript slug, the recorded cwd,
/// the project memory directory and absolute paths inside tool calls all stay
/// valid. Otherwise the home prefix is replaced and the project is re-slugged.
public struct AgentMovePathMap: Sendable, Equatable {
    /// Home directory on the source machine.
    public var sourceHome: String
    /// Home directory on the destination machine.
    public var destinationHome: String
    /// Whether the source home is reachable at the same absolute path on the destination.
    public var sharesHomePath: Bool

    /// Creates a map.
    public init(sourceHome: String, destinationHome: String, sharesHomePath: Bool) {
        self.sourceHome = Self.trimmingTrailingSlash(sourceHome)
        self.destinationHome = Self.trimmingTrailingSlash(destinationHome)
        self.sharesHomePath = sharesHomePath
    }

    /// Whether mapping changes any path under the home directory.
    public var rewritesPaths: Bool {
        !sharesHomePath && sourceHome != destinationHome
    }

    /// The destination path for a source path. Paths outside the home stay as they are.
    public func destinationPath(for sourcePath: String) -> String {
        guard rewritesPaths else { return sourcePath }
        if sourcePath == sourceHome { return destinationHome }
        let prefix = sourceHome + "/"
        guard sourcePath.hasPrefix(prefix) else { return sourcePath }
        return destinationHome + "/" + sourcePath.dropFirst(prefix.count)
    }

    private static func trimmingTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// Claude Code's per-project directory name under `~/.claude/projects`.
public struct ClaudeProjectSlug: Sendable {
    /// Creates a slugger.
    public init() {}

    /// Every character of the absolute cwd that is not an ASCII letter or digit becomes `-`.
    public func slug(forWorkingDirectory path: String) -> String {
        String(path.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9": return Character(scalar)
            default: return "-"
            }
        })
    }
}
