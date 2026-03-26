import Foundation

/// Manages trusted directories for cmux.json command execution.
/// When a directory (or its git repo root) is trusted, `confirm: true` commands
/// from that directory's cmux.json skip the confirmation dialog.
/// Global config (~/.config/cmux/cmux.json) is always trusted.
final class CmuxDirectoryTrust {
    static let shared = CmuxDirectoryTrust()

    private let storePath: String
    private var trustedPaths: Set<String>

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("cmux")
        storePath = appSupport.appendingPathComponent("trusted-directories.json").path

        let fm = FileManager.default
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(atPath: appSupport.path, withIntermediateDirectories: true)
        }

        if let data = fm.contents(atPath: storePath),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            trustedPaths = Set(paths)
        } else {
            trustedPaths = []
        }
    }

    /// Check if a cmux.json path is trusted.
    /// Global config is always trusted. For local configs, check the git repo root
    /// (or the cmux.json parent directory if not in a git repo).
    func isTrusted(configPath: String, globalConfigPath: String) -> Bool {
        if configPath == globalConfigPath { return true }
        let trustKey = Self.trustKey(for: configPath)
        return trustedPaths.contains(trustKey)
    }

    /// Trust the directory containing a cmux.json. If the cmux.json is inside a git
    /// repo, trusts the repo root (covering all subdirectories).
    func trust(configPath: String) {
        let trustKey = Self.trustKey(for: configPath)
        trustedPaths.insert(trustKey)
        save()
    }

    /// Remove trust for a directory.
    func revokeTrust(configPath: String) {
        let trustKey = Self.trustKey(for: configPath)
        trustedPaths.remove(trustKey)
        save()
    }

    /// Remove trust by the trust key directly (as stored/displayed in settings).
    func revokeTrustByPath(_ path: String) {
        trustedPaths.remove(path)
        save()
    }

    /// All currently trusted paths.
    var allTrustedPaths: [String] {
        Array(trustedPaths).sorted()
    }

    /// Replace all trusted paths (used by Settings textarea save).
    func replaceAll(with paths: [String]) {
        trustedPaths = Set(paths)
        save()
    }

    /// Clear all trusted directories.
    func clearAll() {
        trustedPaths.removeAll()
        save()
    }

    // MARK: - Private

    /// Resolve the trust key for a cmux.json path: git repo root if inside a repo,
    /// otherwise the cmux.json's parent directory.
    static func trustKey(for configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if let gitRoot = findGitRoot(from: configDir) {
            return gitRoot
        }
        return configDir
    }

    /// Walk up from `directory` looking for a `.git` directory or file.
    private static func findGitRoot(from directory: String) -> String? {
        let fm = FileManager.default
        var current = directory
        while true {
            let gitPath = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: gitPath) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private func save() {
        let sorted = trustedPaths.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        FileManager.default.createFile(atPath: storePath, contents: data)
    }
}
