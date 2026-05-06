import Darwin
import Foundation

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
    """

    private struct ClaudeNodeOptionsCachePathError: LocalizedError {
        let reason: String
        let path: String

        var errorDescription: String? {
            "Claude NODE_OPTIONS restore module \(reason): \(path)"
        }
    }

    private static let nodeOptionsUnsafePathCharacters =
        CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))

    private static func pathIsUnsafeForNodeOptions(_ path: String) -> Bool {
        path.rangeOfCharacter(from: nodeOptionsUnsafePathCharacters) != nil
    }

    private static func nodeOptionsHomePath(in environment: [String: String]) -> String {
        if let homePath = environment["HOME"], !homePath.isEmpty {
            return homePath
        }
        return NSHomeDirectory()
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
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let restoreModuleURL = root.appendingPathComponent("restore-node-options.cjs", isDirectory: false)
        try writeShimIfChanged(Self.claudeNodeOptionsRestoreModule, to: restoreModuleURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restoreModuleURL.path)
        return restoreModuleURL
    }

    private func claudeNodeOptionsRestoreModuleRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let cacheRoot: URL
#if os(macOS)
        let homePath = Self.nodeOptionsHomePath(in: environment)
        let preferredRoot = URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
        if !Self.pathIsUnsafeForNodeOptions(preferredRoot.path) {
            cacheRoot = preferredRoot
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
            let homePath = Self.nodeOptionsHomePath(in: environment)
            let preferredRoot = URL(fileURLWithPath: homePath, isDirectory: true)
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent("cmux", isDirectory: true)
            if !Self.pathIsUnsafeForNodeOptions(preferredRoot.path) {
                cacheRoot = preferredRoot
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
        let privateBase = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("cmux-\(uid)", isDirectory: true)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: privateBase.path)) == nil else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "fallback cache base is a symlink",
                path: privateBase.path
            )
        }
        try FileManager.default.createDirectory(
            at: privateBase,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateBase.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: privateBase.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard owner == uid else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "fallback cache base is owned by a different uid",
                path: privateBase.path
            )
        }
        let values = try privateBase.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ClaudeNodeOptionsCachePathError(
                reason: "fallback cache base is a symlink",
                path: privateBase.path
            )
        }

        var root = privateBase
        if appScoped {
            root = root.appendingPathComponent("com.cmuxterm.app", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
