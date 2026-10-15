import Foundation

/// A local git checkout and the Cloud Secrets project key it maps to.
///
/// Found by reading files only (no `git` process), so the app can resolve the project of
/// the folder a window is in without spawning anything: walk up to the nearest `.git`
/// (a directory, or a worktree's `gitdir:` file and its `commondir`), read
/// `remote "origin"`'s `url` from the config, and normalize it like
/// ``CloudSecretProjectKey/normalize(remoteURL:)``. A checkout without an origin uses
/// `local/<folder name>`.
public struct CloudSecretProjectCheckout: Hashable, Sendable {
    /// The checkout's top-level folder.
    public let root: URL
    public let projectKey: String

    public init(root: URL, projectKey: String) {
        self.root = root
        self.projectKey = projectKey
    }

    /// The checkout containing `directory`, or nil when it is not inside one.
    public static func locate(from directory: URL) -> CloudSecretProjectCheckout? {
        var current = directory.standardizedFileURL
        while true {
            let dotGit = current.appendingPathComponent(".git")
            if let gitDir = gitDirectory(dotGit: dotGit, root: current) {
                let key = originURL(gitDir: gitDir).flatMap(CloudSecretProjectKey.normalize(remoteURL:))
                    ?? CloudSecretProjectKey.fallback(directoryName: current.lastPathComponent)
                return CloudSecretProjectCheckout(root: current, projectKey: key)
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path || current.path == "/" { return nil }
            current = parent
        }
    }

    /// `.git` as a directory, or the directory a `gitdir: <path>` file points at.
    static func gitDirectory(dotGit: URL, root: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = smallText(dotGit),
              let line = text.split(whereSeparator: \.isNewline).first,
              line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// `remote "origin"`'s url from the repository config (a worktree's lives in its
    /// `commondir`).
    static func originURL(gitDir: URL) -> String? {
        var configDir = gitDir
        if let common = smallText(gitDir.appendingPathComponent("commondir"))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
            configDir = common.hasPrefix("/") ? URL(fileURLWithPath: common) : gitDir.appendingPathComponent(common)
        }
        guard let config = smallText(configDir.appendingPathComponent("config")) else { return nil }
        return originURL(config: config)
    }

    /// Parses git's config syntax for `[remote "origin"] url = …`.
    static func originURL(config: String) -> String? {
        var inOrigin = false
        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                inOrigin = header.lowercased().hasPrefix("remote") && header.hasSuffix("\"origin\"")
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "url" else { continue }
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let unquoted = value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2
                ? String(value.dropFirst().dropLast())
                : value
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

    private static func smallText(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
