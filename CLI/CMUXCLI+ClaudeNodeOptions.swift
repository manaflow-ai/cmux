import Darwin
import Foundation

enum CMUXCLIShimWriter {
    static func writeIfChanged(_ script: String, to url: URL, mode: Int = 0o755) throws {
        let fileManager = FileManager.default
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != script else {
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return
        }
        let directoryURL = url.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try script.write(to: tempURL, atomically: false, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: tempURL.path)
        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }
        } catch {
            let current = try? String(contentsOf: url, encoding: .utf8)
            if current == script {
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                try? fileManager.removeItem(at: tempURL)
                return
            }
            if fileManager.fileExists(atPath: url.path) {
                do {
                    _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
                    try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                    return
                } catch {}
            }
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }
}

extension CMUXCLI {
    private static let claudeNodeOptionsRestoreModule = """
    const hadOriginalNodeOptions = process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT === "1";
    if (hadOriginalNodeOptions) {
      process.env.NODE_OPTIONS = process.env.CMUX_ORIGINAL_NODE_OPTIONS ?? "";
    } else {
      delete process.env.NODE_OPTIONS;
    }
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS;
    delete process.env.CMUX_ORIGINAL_NODE_OPTIONS_PRESENT;
    """ + "\n"

    private struct ClaudeNodeOptionsCachePathError: LocalizedError {
        let reason: String
        let path: String

        var errorDescription: String? {
            "Claude NODE_OPTIONS restore module \(reason): \(path)"
        }
    }

    private struct NodeOptionsFallbackCachePathState {
        let owner: uid_t
        let isSymbolicLink: Bool
    }

    private static let nodeOptionsUnsafePathCharacters =
        CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))

    private static func pathIsUnsafeForNodeOptions(_ path: String) -> Bool {
        path.rangeOfCharacter(from: nodeOptionsUnsafePathCharacters) != nil
    }

    private static func nodeOptionsHomePath(in environment: [String: String]) -> String? {
        guard let homePath = environment["HOME"], !homePath.isEmpty else {
            return nil
        }
        return homePath
    }

    private static func nodeOptionsMacOSSystemCachesRoot() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
    }

    private static func nodeOptionsFallbackCacheBaseURL(for uid: uid_t) -> URL {
        URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("cmux-\(uid)", isDirectory: true)
    }

    private static func nodeOptionsFallbackCachePathState(at url: URL) throws -> NodeOptionsFallbackCachePathState? {
        var statValue = stat()
        let result = lstat(url.path, &statValue)
        if result == 0 {
            return NodeOptionsFallbackCachePathState(
                owner: statValue.st_uid,
                isSymbolicLink: (statValue.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
            )
        }
        if errno == ENOENT {
            return nil
        }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: url.path]
        )
    }

    private static func validateNodeOptionsFallbackCacheBase(_ url: URL, expectedOwner uid: uid_t) throws {
        guard let state = try nodeOptionsFallbackCachePathState(at: url) else {
            return
        }
        guard !state.isSymbolicLink else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "fallback cache base is a symlink",
                path: url.path
            )
        }
        guard state.owner == uid else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "fallback cache base is owned by a different uid",
                path: url.path
            )
        }
    }

    private static func validateNodeOptionsFallbackCacheDirectory(_ url: URL, expectedOwner uid: uid_t) throws {
        guard let state = try nodeOptionsFallbackCachePathState(at: url) else {
            return
        }
        guard !state.isSymbolicLink else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "fallback cache directory is a symlink",
                path: url.path
            )
        }
        guard state.owner == uid else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "fallback cache directory is owned by a different uid",
                path: url.path
            )
        }
    }

    private static func validateNodeOptionsFallbackCacheDirectoryChain(
        from leaf: URL,
        under base: URL,
        expectedOwner uid: uid_t
    ) throws {
        let basePath = base.standardizedFileURL.path
        var current = leaf.standardizedFileURL
        while current.path.hasPrefix(basePath + "/") {
            try validateNodeOptionsFallbackCacheDirectory(current, expectedOwner: uid)
            current.deleteLastPathComponent()
        }
    }

    func createClaudeNodeOptionsRestoreModule() throws -> URL {
        // Use the user's cache directory rather than NSTemporaryDirectory()
        // so the guard module survives macOS `periodic` cleanup of
        // /var/folders/.../T/ (which reaps temp files after ~3 days of no
        // access and breaks long-running Claude sessions). The path must
        // not contain whitespace or quotes, since Node.js parses
        // NODE_OPTIONS syntax and the --require=<path> flag is not quoted.
        let root = try claudeNodeOptionsRestoreModuleRoot()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let uid = getuid()
        let fallbackBase = Self.nodeOptionsFallbackCacheBaseURL(for: uid)
        try Self.validateNodeOptionsFallbackCacheDirectoryChain(
            from: root,
            under: fallbackBase,
            expectedOwner: uid
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let restoreModuleURL = root.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        try CMUXCLIShimWriter.writeIfChanged(Self.claudeNodeOptionsRestoreModule, to: restoreModuleURL, mode: 0o600)
        return restoreModuleURL
    }

    private func claudeNodeOptionsRestoreModuleRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let cacheRoot: URL
#if os(macOS)
        if let homePath = Self.nodeOptionsHomePath(in: environment) {
            let preferredRoot = URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
            if !Self.pathIsUnsafeForNodeOptions(preferredRoot.path) {
                cacheRoot = preferredRoot
            } else if let systemCachesRoot = Self.nodeOptionsMacOSSystemCachesRoot(),
                      !Self.pathIsUnsafeForNodeOptions(systemCachesRoot.path) {
                cacheRoot = systemCachesRoot
            } else {
                cacheRoot = try claudeNodeOptionsFallbackCacheRoot(appScoped: true)
            }
        } else {
            cacheRoot = try claudeNodeOptionsFallbackCacheRoot(appScoped: true)
        }
#else
        if let xdgCacheHome = environment["XDG_CACHE_HOME"],
           !xdgCacheHome.isEmpty,
           xdgCacheHome.hasPrefix("/"),
           !Self.pathIsUnsafeForNodeOptions(xdgCacheHome) {
            cacheRoot = URL(fileURLWithPath: xdgCacheHome, isDirectory: true)
                .appendingPathComponent("cmux", isDirectory: true)
        } else {
            if let homePath = Self.nodeOptionsHomePath(in: environment) {
                let preferredRoot = URL(fileURLWithPath: homePath, isDirectory: true)
                    .appendingPathComponent(".cache", isDirectory: true)
                    .appendingPathComponent("cmux", isDirectory: true)
                if !Self.pathIsUnsafeForNodeOptions(preferredRoot.path) {
                    cacheRoot = preferredRoot
                } else {
                    cacheRoot = try claudeNodeOptionsFallbackCacheRoot(appScoped: false)
                }
            } else {
                cacheRoot = try claudeNodeOptionsFallbackCacheRoot(appScoped: false)
            }
        }
#endif
        let root = cacheRoot.appendingPathComponent("cmux-claude-node-options", isDirectory: true)
        guard !Self.pathIsUnsafeForNodeOptions(root.path) else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "path is unsafe for --require",
                path: root.path
            )
        }
        return root
    }

    private func claudeNodeOptionsFallbackCacheRoot(appScoped: Bool) throws -> URL {
        let uid = getuid()
        let privateBase = Self.nodeOptionsFallbackCacheBaseURL(for: uid)
        try Self.validateNodeOptionsFallbackCacheBase(privateBase, expectedOwner: uid)
        try FileManager.default.createDirectory(
            at: privateBase,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.validateNodeOptionsFallbackCacheBase(privateBase, expectedOwner: uid)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateBase.path)

        var root = privateBase
        if appScoped {
            root = root.appendingPathComponent("com.cmuxterm.app", isDirectory: true)
            try Self.validateNodeOptionsFallbackCacheDirectory(root, expectedOwner: uid)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.validateNodeOptionsFallbackCacheDirectory(root, expectedOwner: uid)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        guard !Self.pathIsUnsafeForNodeOptions(root.path) else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "path is unsafe for --require",
                path: root.path
            )
        }
        return root
    }

    func mergedNodeOptions(existing: String?, restoreModulePath: String) -> String {
        let requireOption = "--require=\(restoreModulePath)"
        let memoryOption = "--max-old-space-size=4096"
        let cleanedExisting = cleanedNodeOptions(existing)
        guard !cleanedExisting.isEmpty else {
            return "\(requireOption) \(memoryOption)"
        }
        return "\(requireOption) \(memoryOption) \(cleanedExisting)"
    }

    private func cleanedNodeOptions(_ existing: String?) -> String {
        let tokens = (existing ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "" }

        var filtered: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size" {
                index += min(2, tokens.count - index)
                continue
            }
            if token.hasPrefix("--max-old-space-size=") {
                index += 1
                continue
            }
            filtered.append(token)
            index += 1
        }
        return filtered.joined(separator: " ")
    }

    func normalizedNodeOptionsForRestore(_ existing: String) -> String {
        let tokens = existing
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return "" }

        var normalized: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--max-old-space-size", index + 1 < tokens.count {
                normalized.append("--max-old-space-size=\(tokens[index + 1])")
                index += 2
                continue
            }
            normalized.append(token)
            index += 1
        }
        return normalized.joined(separator: " ")
    }
}
