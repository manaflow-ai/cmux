import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct NodeOptionsRestoreDirectoryError: Error, Equatable {
    public let attemptedPaths: [String]
}

public enum NodeOptionsSupport {
    public static let restoreModuleFilename = "restore-node-options.cjs"

    public static func claudeRestoreDirectory(
        homePath: String?,
        appSupportDirectory: URL? = nil,
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        systemTempDirectory: URL? = URL(fileURLWithPath: "/tmp", isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> URL {
        let durableCandidates = claudeRestoreDirectoryCandidates(
            homePath: homePath,
            appSupportDirectory: appSupportDirectory
        )
        for candidate in durableCandidates
        where prepareWritableRestoreDirectory(candidate, fileManager: fileManager) {
            return candidate
        }

        let tempCandidates = temporaryRestoreDirectoryCandidates(
            tempDirectory: tempDirectory,
            systemTempDirectory: systemTempDirectory
        )
        for candidate in tempCandidates
        where prepareSecureTemporaryRestoreDirectory(candidate, fileManager: fileManager) {
            return candidate
        }

        throw NodeOptionsRestoreDirectoryError(
            attemptedPaths: (durableCandidates + tempCandidates).map(\.path)
        )
    }

    private static func claudeRestoreDirectoryCandidates(
        homePath: String?,
        appSupportDirectory: URL?
    ) -> [URL] {
        var appSupportRoots: [URL] = []
        let trimmedHome = homePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedHome, !trimmedHome.isEmpty {
            appSupportRoots.append(
                URL(fileURLWithPath: trimmedHome, isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        }
        if let appSupportDirectory {
            appSupportRoots.append(appSupportDirectory)
        }
        if appSupportRoots.isEmpty {
            appSupportRoots.append(
                URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            )
        }

        var seen = Set<String>()
        return appSupportRoots.compactMap { appSupport in
            let restoreDirectory = appSupport
                .appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent("node-options", isDirectory: true)
                .standardizedFileURL
            guard seen.insert(restoreDirectory.path).inserted else { return nil }
            return restoreDirectory
        }
    }

    private static func temporaryRestoreDirectoryCandidates(
        tempDirectory: URL,
        systemTempDirectory: URL?
    ) -> [URL] {
        var candidates = [temporaryRestoreDirectory(under: tempDirectory)]
        if let systemTempDirectory {
            candidates.append(temporaryRestoreDirectory(under: systemTempDirectory))
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func temporaryRestoreDirectory(under tempDirectory: URL) -> URL {
        tempDirectory
            .standardizedFileURL
            .appendingPathComponent("cmux-node-options-\(getuid())", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("node-options", isDirectory: true)
    }

    private static func prepareSecureTemporaryRestoreDirectory(
        _ restoreDirectory: URL,
        fileManager: FileManager
    ) -> Bool {
        let root = restoreDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        guard !isSymbolicLink(root, fileManager: fileManager) else {
            return false
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return false
        }

        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard !isSymbolicLink(root, fileManager: fileManager) else {
                return false
            }
            let attributes = try fileManager.attributesOfItem(atPath: root.path)
            if let owner = attributes[.ownerAccountID] as? NSNumber,
               owner.uint32Value != getuid() {
                return false
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            return prepareWritableRestoreDirectory(restoreDirectory, fileManager: fileManager)
        } catch {
            return false
        }
    }

    private static func prepareWritableRestoreDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard !isSymbolicLink(directory, fileManager: fileManager) else {
            return false
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            guard !isSymbolicLink(directory, fileManager: fileManager) else {
                return false
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }

            let probeURL = directory.appendingPathComponent(
                ".cmux-node-options-probe-\(UUID().uuidString)",
                isDirectory: false
            )
            guard fileManager.createFile(atPath: probeURL.path, contents: Data(), attributes: nil) else {
                return false
            }
            try? fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
        } catch {
            return false
        }
    }

    public static func requirePath(_ path: String) -> String {
        quoteTokenIfNeeded(path)
    }

    public static func tokens(_ rawValue: String?) -> [String] {
        guard let rawValue else { return [] }

        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in rawValue {
            if let activeQuote = quote {
                if escaping {
                    if character == "\\" || character == activeQuote {
                        current.append(character)
                    } else {
                        current.append("\\")
                        current.append(character)
                    }
                    escaping = false
                    continue
                }
                if character == "\\" {
                    escaping = true
                    continue
                }
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if escaping {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    public static func joinedTokens(_ tokens: [String]) -> String {
        tokens.map(quoteTokenIfNeeded).joined(separator: " ")
    }

    public static func sanitizedNodeOptions(_ rawValue: String?) -> String? {
        let strippedTokens = tokensRemovingCmuxRestoreEntries(tokens(rawValue))
        guard !strippedTokens.isEmpty else { return nil }

        let joined = joinedTokens(strippedTokens)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    public static func normalizedNodeOptionsForRestore(_ rawValue: String?) -> String? {
        let strippedTokens = tokensRemovingCmuxRestoreEntries(tokens(rawValue))
        guard !strippedTokens.isEmpty else { return nil }

        var normalized: [String] = []
        var index = 0
        while index < strippedTokens.count {
            let token = strippedTokens[index]

            if token == "--max-old-space-size", index + 1 < strippedTokens.count {
                normalized.append("--max-old-space-size=\(strippedTokens[index + 1])")
                index += 2
                continue
            }
            normalized.append(token)
            index += 1
        }
        let joined = joinedTokens(normalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    public static func tokensRemovingCmuxRestoreEntries(_ tokens: [String]) -> [String] {
        var filtered: [String] = []
        var index = 0
        var shouldDropInjectedHeapCap = false
        while index < tokens.count {
            let token = tokens[index]

            if shouldDropInjectedHeapCap, isInjectedNodeHeapCap(tokens, index: index) {
                index += nodeHeapCapWidth(tokens, index: index)
                shouldDropInjectedHeapCap = false
                continue
            }
            shouldDropInjectedHeapCap = false

            if isRequireOption(token), index + 1 < tokens.count,
               isCmuxRestoreModulePath(tokens[index + 1]) {
                index += 2
                shouldDropInjectedHeapCap = true
                continue
            }
            if let path = inlineRequireOptionPath(token),
               isCmuxRestoreModulePath(path) {
                index += 1
                shouldDropInjectedHeapCap = true
                continue
            }

            filtered.append(token)
            index += 1
        }
        return filtered
    }

    public static func isCmuxRestoreModulePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard url.lastPathComponent == restoreModuleFilename else {
            return false
        }
        let components = url.pathComponents
        return components.suffix(3) == ["cmux", "node-options", restoreModuleFilename]
            || components.suffix(2) == ["cmux-claude-node-options", restoreModuleFilename]
    }

    public static func isRequireOption(_ token: String) -> Bool {
        token == "--require" || token == "-r"
    }

    public static func inlineRequireOptionPath(_ token: String) -> String? {
        for prefix in ["--require=", "-r="] where token.hasPrefix(prefix) {
            return String(token.dropFirst(prefix.count))
        }
        return nil
    }

    public static func isInjectedNodeHeapCap(_ tokens: [String], index: Int) -> Bool {
        guard index < tokens.count else { return false }
        let token = tokens[index]
        if token == "--max-old-space-size=4096" {
            return true
        }
        return token == "--max-old-space-size"
            && index + 1 < tokens.count
            && tokens[index + 1] == "4096"
    }

    public static func nodeHeapCapWidth(_ tokens: [String], index: Int) -> Int {
        guard index < tokens.count,
              tokens[index] == "--max-old-space-size",
              index + 1 < tokens.count else {
            return 1
        }
        return 2
    }

    private static func quoteTokenIfNeeded(_ value: String) -> String {
        let charactersRequiringQuotes = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\\\""))
        guard value.rangeOfCharacter(from: charactersRequiringQuotes) != nil else {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
