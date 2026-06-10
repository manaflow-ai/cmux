import Darwin
import Foundation


// MARK: - Agent Turn Diff Baseline Recording and Pruning
extension CMUXCLI {
    private func agentTurnDiffBaselineSnapshotRootURL(storePath: String) -> URL {
        URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("agent-turn-diff-baseline-snapshots", isDirectory: true)
    }

    private func agentTurnDiffBaselineSnapshotStagingRootURL(storePath: String) -> URL {
        URL(fileURLWithPath: storePath)
            .deletingLastPathComponent()
            .appendingPathComponent("agent-turn-diff-baseline-snapshots-staging", isDirectory: true)
    }

    private func agentTurnDiffBaselineSnapshotDirectoryURL(
        snapshotId: String,
        storePath: String
    ) -> URL? {
        guard snapshotId.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return agentTurnDiffBaselineSnapshotRootURL(storePath: storePath)
            .appendingPathComponent(snapshotId, isDirectory: true)
    }

    private func agentTurnDiffBaselineStagedSnapshotDirectoryURL(
        snapshotId: String,
        storePath: String
    ) -> URL? {
        guard snapshotId.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return agentTurnDiffBaselineSnapshotStagingRootURL(storePath: storePath)
            .appendingPathComponent(snapshotId, isDirectory: true)
    }

    func agentTurnDiffBaselineSnapshotFileURL(
        path: String,
        record: CMUXAgentTurnDiffBaselineRecord,
        storePath: String
    ) -> URL? {
        guard let snapshotId = record.untrackedSnapshotId,
              let snapshotDirectory = agentTurnDiffBaselineSnapshotDirectoryURL(
                snapshotId: snapshotId,
                storePath: storePath
              ),
              let components = safeRelativePathComponents(path) else {
            return nil
        }
        let filesRoot = snapshotDirectory.appendingPathComponent("files", isDirectory: true)
        let file = components.reduce(filesRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
        let standardizedRoot = filesRoot.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedFile = file.standardizedFileURL.resolvingSymlinksInPath()
        guard standardizedFile.path.hasPrefix(standardizedRoot.path + "/") else {
            return nil
        }
        return standardizedFile
    }

    func gitUntrackedPathHash(_ path: String, in repoRoot: String) throws -> String {
        try gitSingleLine(["hash-object", "--no-filters", "--", path], in: repoRoot)
    }

    private func gitUntrackedSnapshotFileHash(_ url: URL, in repoRoot: String) throws -> String {
        try gitSingleLine(["hash-object", "--no-filters", "--", url.path], in: repoRoot)
    }

    private func posixError(_ errnoValue: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errnoValue) ?? .EIO)
    }

    private func setPrivateDirectoryPermissions(at url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func createPrivateDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPrivateDirectoryPermissions(at: url)
    }

    private func copyPrivateFile(from sourceURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let fd = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fd >= 0 else {
            throw posixError(errno)
        }
        var shouldClose = true
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return
                }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw posixError(errno)
                    }
                    if written == 0 {
                        throw POSIXError(.EIO)
                    }
                    offset += written
                }
            }
            if Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) != 0 {
                throw posixError(errno)
            }
            if Darwin.close(fd) != 0 {
                shouldClose = false
                throw posixError(errno)
            }
            shouldClose = false
        } catch {
            if shouldClose {
                Darwin.close(fd)
            }
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func gitUntrackedPathHashes(
        paths: [String],
        in repoRoot: String,
        storePath: String
    ) throws -> (snapshotId: String?, hashes: [String: String]) {
        guard !paths.isEmpty else {
            return (nil, [:])
        }
        let snapshotId = UUID().uuidString
        guard let snapshotDirectory = agentTurnDiffBaselineStagedSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) else {
            return (nil, [:])
        }
        try createPrivateDirectory(at: agentTurnDiffBaselineSnapshotStagingRootURL(storePath: storePath))
        try createPrivateDirectory(at: snapshotDirectory)
        let filesRoot = snapshotDirectory.appendingPathComponent("files", isDirectory: true)
        try createPrivateDirectory(at: filesRoot)
        var hashes: [String: String] = [:]
        var capturedBytes: UInt64 = 0
        for path in paths {
            guard hashes.count < CMUXAgentTurnUntrackedSnapshotLimits.maxFiles,
                  let sourceURL = safeRepoPathURL(relativePath: path, repoRoot: repoRoot),
                  let components = safeRelativePathComponents(path) else {
                continue
            }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else {
                continue
            }
            let fileSize = UInt64((attributes[.size] as? NSNumber)?.int64Value ?? 0)
            guard fileSize <= CMUXAgentTurnUntrackedSnapshotLimits.maxFileBytes,
                  capturedBytes + fileSize <= CMUXAgentTurnUntrackedSnapshotLimits.maxTotalBytes else {
                continue
            }
            do {
                let destinationURL = components.reduce(filesRoot) { partial, component in
                    partial.appendingPathComponent(component, isDirectory: false)
                }
                try createPrivateDirectory(at: destinationURL.deletingLastPathComponent())
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try copyPrivateFile(from: sourceURL, to: destinationURL)
                let hash = try gitUntrackedSnapshotFileHash(destinationURL, in: repoRoot)
                hashes[path] = hash
                capturedBytes += fileSize
            } catch {
                continue
            }
        }
        if hashes.isEmpty {
            try? FileManager.default.removeItem(at: snapshotDirectory)
            return (nil, [:])
        }
        return (snapshotId, hashes)
    }

    private func publishAgentTurnDiffBaselineSnapshot(snapshotId: String, storePath: String) throws {
        guard let stagedDirectory = agentTurnDiffBaselineStagedSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ), let snapshotDirectory = agentTurnDiffBaselineSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) else {
            return
        }
        guard FileManager.default.fileExists(atPath: stagedDirectory.path) else {
            return
        }
        try createPrivateDirectory(at: snapshotDirectory.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: snapshotDirectory.path) {
            try FileManager.default.removeItem(at: snapshotDirectory)
        }
        try FileManager.default.moveItem(at: stagedDirectory, to: snapshotDirectory)
        try setPrivateDirectoryPermissions(at: snapshotDirectory)
    }

    private func removeAgentTurnDiffBaselineSnapshot(snapshotId: String, storePath: String) {
        if let snapshotDirectory = agentTurnDiffBaselineSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) {
            try? FileManager.default.removeItem(at: snapshotDirectory)
        }
        if let stagedDirectory = agentTurnDiffBaselineStagedSnapshotDirectoryURL(
            snapshotId: snapshotId,
            storePath: storePath
        ) {
            try? FileManager.default.removeItem(at: stagedDirectory)
        }
    }

    func joinedGitDiffPatches(_ patches: [String]) -> String {
        let trimmed = patches.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return "" }
        return trimmed.joined(separator: "\n") + "\n"
    }

    func recordAgentTurnDiffBaseline(
        agent: String,
        sessionId: String,
        turnId: String?,
        cwd: String?,
        workspaceId: String,
        surfaceId: String,
        env: [String: String] = ProcessInfo.processInfo.environment,
        preserveExistingTurnBaseline: Bool = false
    ) throws {
        guard let cwd = normalizedDiffSourceValue(cwd),
              let workspaceId = normalizedDiffSourceValue(workspaceId),
              let surfaceId = normalizedDiffSourceValue(surfaceId) else {
            return
        }
        let repoRoot = try gitRepoRoot(startingAt: cwd)
        let baseCommit = try agentTurnDiffBaselineCommit(in: repoRoot)
        let untrackedPaths = try gitUntrackedPaths(in: repoRoot)
        let storePath = CMUXAgentTurnDiffBaselineFile.path(env: env)
        let untrackedSnapshot = try gitUntrackedPathHashes(
            paths: untrackedPaths,
            in: repoRoot,
            storePath: storePath
        )
        let record = CMUXAgentTurnDiffBaselineRecord(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: normalizedDiffSourceValue(sessionId) ?? "",
            turnId: normalizedDiffSourceValue(turnId),
            agent: normalizedDiffSourceValue(agent) ?? "agent",
            repoRoot: repoRoot,
            baseCommit: baseCommit,
            untrackedPaths: untrackedPaths.isEmpty ? nil : untrackedPaths,
            untrackedPathHashes: untrackedSnapshot.hashes.isEmpty ? nil : untrackedSnapshot.hashes,
            untrackedSnapshotId: untrackedSnapshot.snapshotId,
            capturedAt: Date().timeIntervalSince1970
        )
        do {
            var removedRecords: [CMUXAgentTurnDiffBaselineRecord] = []
            var shouldRemoveNewSnapshot = untrackedSnapshot.snapshotId != nil
            try updateAgentTurnDiffBaselineStore(path: storePath, update: { store in
                func matchesCurrentScope(_ existing: CMUXAgentTurnDiffBaselineRecord) -> Bool {
                    standardizedDiffSourcePath(existing.repoRoot) == repoRoot &&
                        diffScopeIdentifierEquals(existing.workspaceId, workspaceId) &&
                        diffScopeIdentifierEquals(existing.surfaceId, surfaceId) &&
                        existing.sessionId == record.sessionId
                }

                let previousRecords = store.records
                if preserveExistingTurnBaseline,
                   let turnId = record.turnId,
                   store.records.contains(where: { matchesCurrentScope($0) && $0.turnId == turnId }) {
                    pruneAgentTurnDiffBaselineStore(&store)
                    removedRecords = previousRecords.filter { previous in
                        !store.records.contains { agentTurnDiffBaselineRecordEquals($0, previous) }
                    }
                    removedRecords.append(record)
                    return
                }

                if let snapshotId = untrackedSnapshot.snapshotId {
                    try publishAgentTurnDiffBaselineSnapshot(snapshotId: snapshotId, storePath: storePath)
                    shouldRemoveNewSnapshot = false
                }
                store.records.removeAll { existing in
                    guard matchesCurrentScope(existing) else {
                        return false
                    }
                    if let turnId = record.turnId {
                        return existing.turnId == turnId
                    }
                    return existing.turnId == nil
                }
                store.records.append(record)
                pruneAgentTurnDiffBaselineStore(&store)
                removedRecords = previousRecords.filter { previous in
                    !store.records.contains { agentTurnDiffBaselineRecordEquals($0, previous) }
                }
            }, afterWrite: { store in
                pruneAgentTurnDiffBaselineArtifacts(
                    storePath: storePath,
                    removedRecords: removedRecords,
                    retainedRecords: store.records
                )
            })
            if shouldRemoveNewSnapshot, let snapshotId = untrackedSnapshot.snapshotId {
                removeAgentTurnDiffBaselineSnapshot(snapshotId: snapshotId, storePath: storePath)
            }
        } catch {
            if let snapshotId = untrackedSnapshot.snapshotId {
                removeAgentTurnDiffBaselineSnapshot(snapshotId: snapshotId, storePath: storePath)
            }
            throw error
        }
    }

    private func agentTurnDiffBaselineCommit(in repoRoot: String) throws -> String {
        let stashResult = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "stash", "create", "cmux last turn baseline"],
            timeout: 60
        )
        if stashResult.timedOut {
            throw CLIError(message: "git stash create timed out")
        }
        if stashResult.status == 0,
           let stashCommit = normalizedDiffSourceValue(stashResult.stdout) {
            _ = try gitStdout(["update-ref", agentTurnDiffBaselineRefName(for: stashCommit), stashCommit], in: repoRoot)
            return stashCommit
        }
        if let headCommit = try? gitSingleLine(["rev-parse", "HEAD"], in: repoRoot) {
            return headCommit
        }
        return try gitSingleLine(["hash-object", "-t", "tree", "/dev/null"], in: repoRoot)
    }

    private func agentTurnDiffBaselineRefName(for commit: String) -> String {
        "refs/cmux/last-turn/\(commit)"
    }

    private func agentTurnDiffBaselineUntrackedRefName(for blob: String) -> String {
        "refs/cmux/last-turn/untracked/\(blob)"
    }

    /// Returns the most recent last-turn diff baseline recorded for the given
    /// workspace/surface, or `nil` when no baseline has been recorded yet.
    ///
    /// A missing baseline is not an error: it means there is simply nothing to
    /// diff for the last turn, so callers render the friendly empty diff state
    /// (with the source switcher) rather than surfacing a raw CLI error.
    func latestAgentTurnDiffBaseline(
        repoRoot: String,
        workspaceId: String,
        surfaceId: String,
        env: [String: String]
    ) throws -> CMUXAgentTurnDiffBaselineRecord? {
        let store = try readAgentTurnDiffBaselineStore(path: CMUXAgentTurnDiffBaselineFile.path(env: env))
        let repoRoot = standardizedDiffSourcePath(repoRoot)
        let candidates = store.records.filter { record in
            standardizedDiffSourcePath(record.repoRoot) == repoRoot
                && diffScopeIdentifierEquals(record.workspaceId, workspaceId)
                && diffScopeIdentifierEquals(record.surfaceId, surfaceId)
        }
        return candidates.max(by: { $0.capturedAt < $1.capturedAt })
    }

    private func readAgentTurnDiffBaselineStore(path: String) throws -> CMUXAgentTurnDiffBaselineStore {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CMUXAgentTurnDiffBaselineStore()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CMUXAgentTurnDiffBaselineStore.self, from: data)
    }

    private func updateAgentTurnDiffBaselineStore(
        path: String,
        update: (inout CMUXAgentTurnDiffBaselineStore) throws -> Void,
        afterWrite: ((CMUXAgentTurnDiffBaselineStore) -> Void)? = nil
    ) throws {
        let url = URL(fileURLWithPath: path)
        try createPrivateDirectory(at: url.deletingLastPathComponent())
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        if fd < 0 {
            throw CLIError(message: "Failed to open diff baseline lock: \(lockPath)")
        }
        defer { Darwin.close(fd) }

        if flock(fd, LOCK_EX) != 0 {
            throw CLIError(message: "Failed to lock diff baseline store: \(path)")
        }
        defer { _ = flock(fd, LOCK_UN) }
        if Darwin.fchmod(fd, mode_t(S_IRUSR | S_IWUSR)) != 0 {
            throw posixError(errno)
        }

        var store = (try? readAgentTurnDiffBaselineStore(path: path)) ?? CMUXAgentTurnDiffBaselineStore()
        try update(&store)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        afterWrite?(store)
    }

    private func pruneAgentTurnDiffBaselineStore(_ store: inout CMUXAgentTurnDiffBaselineStore) {
        let cutoff = Date().timeIntervalSince1970 - 60 * 60 * 24 * 7
        store.records = store.records
            .filter { $0.capturedAt >= cutoff }
            .sorted { $0.capturedAt > $1.capturedAt }
        if store.records.count > 200 {
            store.records.removeSubrange(200..<store.records.count)
        }
    }

    private func pruneAgentTurnDiffBaselineArtifacts(
        storePath: String,
        removedRecords: [CMUXAgentTurnDiffBaselineRecord],
        retainedRecords: [CMUXAgentTurnDiffBaselineRecord]
    ) {
        pruneAgentTurnDiffBaselineRefs(
            removedRecords: removedRecords,
            retainedRecords: retainedRecords
        )
        pruneAgentTurnDiffBaselineSnapshots(storePath: storePath, retainedRecords: retainedRecords)
    }

    private func pruneAgentTurnDiffBaselineRefs(
        removedRecords: [CMUXAgentTurnDiffBaselineRecord],
        retainedRecords: [CMUXAgentTurnDiffBaselineRecord]
    ) {
        var deletedKeys: Set<String> = []
        for record in removedRecords {
            let repoRoot = standardizedDiffSourcePath(record.repoRoot)
            let key = "\(repoRoot)\u{0}\(record.baseCommit)"
            guard deletedKeys.insert(key).inserted else { continue }
            let stillRetained = retainedRecords.contains { retained in
                standardizedDiffSourcePath(retained.repoRoot) == repoRoot
                    && retained.baseCommit == record.baseCommit
            }
            guard !stillRetained else { continue }
            _ = CLIProcessRunner.runProcess(
                executablePath: "/usr/bin/env",
                arguments: ["git", "-C", repoRoot, "update-ref", "-d", agentTurnDiffBaselineRefName(for: record.baseCommit)],
                timeout: 30
            )
        }
        var deletedBlobKeys: Set<String> = []
        for record in removedRecords {
            let repoRoot = standardizedDiffSourcePath(record.repoRoot)
            let blobs = Set(record.untrackedPathHashes.map { Array($0.values) } ?? [])
            for blob in blobs {
                let key = "\(repoRoot)\u{0}\(blob)"
                guard deletedBlobKeys.insert(key).inserted else { continue }
                let stillRetained = retainedRecords.contains { retained in
                    standardizedDiffSourcePath(retained.repoRoot) == repoRoot
                        && (retained.untrackedPathHashes?.values.contains(blob) ?? false)
                }
                guard !stillRetained else { continue }
                _ = CLIProcessRunner.runProcess(
                    executablePath: "/usr/bin/env",
                    arguments: ["git", "-C", repoRoot, "update-ref", "-d", agentTurnDiffBaselineUntrackedRefName(for: blob)],
                    timeout: 30
                )
            }
        }
    }

    private func pruneAgentTurnDiffBaselineSnapshots(
        storePath: String,
        retainedRecords: [CMUXAgentTurnDiffBaselineRecord]
    ) {
        let rootURL = agentTurnDiffBaselineSnapshotRootURL(storePath: storePath)
        let retainedSnapshotIds = Set(retainedRecords.compactMap(\.untrackedSnapshotId))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for entry in entries {
            guard !retainedSnapshotIds.contains(entry.lastPathComponent) else {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func agentTurnDiffBaselineRecordEquals(
        _ lhs: CMUXAgentTurnDiffBaselineRecord,
        _ rhs: CMUXAgentTurnDiffBaselineRecord
    ) -> Bool {
        standardizedDiffSourcePath(lhs.repoRoot) == standardizedDiffSourcePath(rhs.repoRoot)
            && diffScopeIdentifierEquals(lhs.workspaceId, rhs.workspaceId)
            && diffScopeIdentifierEquals(lhs.surfaceId, rhs.surfaceId)
            && lhs.sessionId == rhs.sessionId
            && lhs.turnId == rhs.turnId
            && lhs.agent == rhs.agent
            && lhs.baseCommit == rhs.baseCommit
            && lhs.untrackedPaths == rhs.untrackedPaths
            && lhs.untrackedPathHashes == rhs.untrackedPathHashes
            && lhs.untrackedSnapshotId == rhs.untrackedSnapshotId
            && lhs.capturedAt == rhs.capturedAt
    }

    private func diffScopeIdentifierEquals(_ lhs: String, _ rhs: String) -> Bool {
        if let lhsUUID = UUID(uuidString: lhs),
           let rhsUUID = UUID(uuidString: rhs) {
            return lhsUUID == rhsUUID
        }
        return lhs == rhs
    }

    func normalizedDiffSourceValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    func standardizedDiffSourcePath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }

}
