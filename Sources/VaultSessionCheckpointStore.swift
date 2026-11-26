import Foundation

/// Persists MANUAL checkpoints per session as one small JSON file under
/// Application Support. Derived turn checkpoints are never stored — they are
/// recomputed from the transcript on demand.
actor VaultSessionCheckpointStore {
    static let shared = VaultSessionCheckpointStore()

    /// Manual checkpoints kept per session; oldest dropped beyond this.
    static let maxCheckpointsPerSession = 100

    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootDirectory = base
                .appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent("VaultCheckpoints", isDirectory: true)
        }
    }

    func checkpoints(agentID: String, sessionID: String) -> [VaultSessionCheckpoint] {
        let url = fileURL(agentID: agentID, sessionID: sessionID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        // Corrupt file tolerance: unreadable stores start empty rather than
        // wedging the timeline.
        return (try? JSONDecoder.vaultCheckpoints.decode([VaultSessionCheckpoint].self, from: data)) ?? []
    }

    @discardableResult
    func append(
        _ checkpoint: VaultSessionCheckpoint,
        agentID: String,
        sessionID: String
    ) throws -> [VaultSessionCheckpoint] {
        var all = checkpoints(agentID: agentID, sessionID: sessionID)
        all.append(checkpoint)
        if all.count > Self.maxCheckpointsPerSession {
            all.removeFirst(all.count - Self.maxCheckpointsPerSession)
        }
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.vaultCheckpoints.encode(all)
        try data.write(to: fileURL(agentID: agentID, sessionID: sessionID), options: .atomic)
        return all
    }

    nonisolated func fileURL(agentID: String, sessionID: String) -> URL {
        rootDirectory.appendingPathComponent(
            Self.sanitizedComponent(agentID) + "-" + Self.sanitizedComponent(sessionID) + ".json"
        )
    }

    /// Path-safe file-name component: anything outside [A-Za-z0-9._-] becomes "_".
    nonisolated static func sanitizedComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(mapped)
        return sanitized.isEmpty ? "_" : sanitized
    }
}

private extension JSONEncoder {
    static var vaultCheckpoints: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var vaultCheckpoints: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Resolves a workspace's current git HEAD sha with bounded file reads and no
/// subprocesses. Supports detached HEAD, one level of symbolic ref, worktree
/// `gitdir:` indirection, and packed-refs fallback.
enum VaultGitHeadReader {
    /// Bounded read for any file this reader touches.
    nonisolated static let fileByteCap = 1024 * 1024

    nonisolated static func headSHA(
        workspacePath: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard let gitDirectory = resolveGitDirectory(
            workspacePath: workspacePath,
            fileManager: fileManager
        ) else {
            return nil
        }
        guard let head = readBounded(gitDirectory.appendingPathComponent("HEAD"), fileManager: fileManager)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if isSHA(head) { return head }
        guard head.hasPrefix("ref: ") else { return nil }
        let refName = String(head.dropFirst("ref: ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refName.isEmpty, !refName.contains("..") else { return nil }
        if let direct = readBounded(gitDirectory.appendingPathComponent(refName), fileManager: fileManager)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isSHA(direct) {
            return direct
        }
        // Worktree git dirs keep shared refs in the common dir.
        if let commonPath = readBounded(gitDirectory.appendingPathComponent("commondir"), fileManager: fileManager)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !commonPath.isEmpty {
            let commonDirectory = commonPath.hasPrefix("/")
                ? URL(fileURLWithPath: commonPath)
                : gitDirectory.appendingPathComponent(commonPath)
            if let direct = readBounded(commonDirectory.appendingPathComponent(refName), fileManager: fileManager)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               isSHA(direct) {
                return direct
            }
            if let packed = packedRefSHA(ref: refName, gitDirectory: commonDirectory, fileManager: fileManager) {
                return packed
            }
        }
        return packedRefSHA(ref: refName, gitDirectory: gitDirectory, fileManager: fileManager)
    }

    nonisolated private static func resolveGitDirectory(
        workspacePath: String,
        fileManager: FileManager
    ) -> URL? {
        let dotGit = URL(fileURLWithPath: workspacePath).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        // `.git` FILE: "gitdir: <path>" indirection (worktrees, submodules) —
        // one level only.
        guard let contents = readBounded(dotGit, fileManager: fileManager)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              contents.hasPrefix("gitdir:") else {
            return nil
        }
        let target = String(contents.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        let resolved = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : URL(fileURLWithPath: workspacePath).appendingPathComponent(target).standardizedFileURL
        var resolvedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &resolvedIsDirectory),
              resolvedIsDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    nonisolated private static func packedRefSHA(
        ref: String,
        gitDirectory: URL,
        fileManager: FileManager
    ) -> String? {
        guard let packed = readBounded(
            gitDirectory.appendingPathComponent("packed-refs"),
            fileManager: fileManager
        ) else {
            return nil
        }
        for line in packed.split(separator: "\n") {
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1] == Substring(ref) else { continue }
            let sha = String(parts[0])
            return isSHA(sha) ? sha : nil
        }
        return nil
    }

    nonisolated private static func readBounded(_ url: URL, fileManager: FileManager) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: fileByteCap) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func isSHA(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.allSatisfy { $0.isHexDigit }
    }
}
