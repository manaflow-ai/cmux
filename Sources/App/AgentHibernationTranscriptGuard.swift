import CMUXAgentLaunch
import Darwin
import Foundation

enum AgentHibernationTranscriptGuard {
    static let restoreCheckDelaysSeconds: [UInt64] = [20, 60, 180, 600]
    private static let maxScannedLineBytes = 16 * 1024 * 1024
    private static let recoveryMetadataName = "com.cmux.agent-transcript-recovery"
    private static let maxRecoveryMetadataBytes = 64 * 1024
    private static let maxStartupRecoverySnapshots = 256
    private static let recoveryLockFilename = ".agent-transcript-recovery.lock"
    private static let maxRecoveryCursorBytes = 16 * 1024

    private struct RecoveryProcessIdentity: Codable, Equatable {
        let processId: Int32
        let processStartSeconds: Int64
        let processStartMicroseconds: Int64

        init(_ identity: AgentPIDProcessIdentity) {
            processId = identity.pid
            processStartSeconds = identity.startSeconds
            processStartMicroseconds = identity.startMicroseconds
        }

        var processIdentity: AgentPIDProcessIdentity? {
            guard processId > 0,
                  processStartSeconds >= 0,
                  processStartMicroseconds >= 0,
                  processStartMicroseconds < 1_000_000 else {
                return nil
            }
            return AgentPIDProcessIdentity(
                pid: processId,
                startSeconds: processStartSeconds,
                startMicroseconds: processStartMicroseconds
            )
        }
    }

    private struct RecoveryMetadata: Codable {
        let version: Int
        let sessionId: String
        let transcriptPath: String
        let snapshotPath: String
        let capturedAt: Date?
        let liveFileNumber: UInt64?
        let liveFileSize: UInt64?
        let liveFileModificationDate: Date?
        let ownerProcessId: Int32?
        let ownerProcessStartSeconds: Int64?
        let ownerProcessStartMicroseconds: Int64?
        let ownerRuntimeId: String?
        let ownerBundleIdentifier: String?
        let guardedProcesses: [RecoveryProcessIdentity]?

        var liveFileVersion: TeardownTranscriptFileVersion? {
            guard let liveFileNumber,
                  let liveFileSize,
                  let liveFileModificationDate else {
                return nil
            }
            return TeardownTranscriptFileVersion(
                fileNumber: liveFileNumber,
                size: liveFileSize,
                modificationDate: liveFileModificationDate
            )
        }

        var ownerProcessIdentity: AgentPIDProcessIdentity? {
            guard let ownerProcessId,
                  let ownerProcessStartSeconds,
                  let ownerProcessStartMicroseconds,
                  ownerProcessId > 0,
                  ownerProcessStartSeconds >= 0,
                  ownerProcessStartMicroseconds >= 0,
                  ownerProcessStartMicroseconds < 1_000_000 else {
                return nil
            }
            return AgentPIDProcessIdentity(
                pid: ownerProcessId,
                startSeconds: ownerProcessStartSeconds,
                startMicroseconds: ownerProcessStartMicroseconds
            )
        }
    }

    private struct PendingRecoverySnapshot {
        let url: URL
        let metadata: RecoveryMetadata
        let capturedAt: Date
        let modificationDate: Date
    }

    static func resolveTranscriptPath(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey? = nil,
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        guard agent.kind == .claude,
              isSafeSessionIdPathComponent(agent.sessionId) else {
            return nil
        }
        return resolveClaudeTranscriptPath(
            agent: agent,
            panelKey: panelKey,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    static func transcriptHasConversationTurns(
        atPath path: String,
        fileManager: FileManager = .default,
        maxScannedLineBytes: Int = Self.maxScannedLineBytes
    ) -> Bool {
        boundedTranscriptHasConversationTurns(
            atPath: path,
            fileManager: fileManager,
            maxScannedLineBytes: maxScannedLineBytes
        )
    }

    static func snapshotBeforeTeardown(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey? = nil,
        guardedProcessIDs: Set<Int> = [],
        homeDirectory: String = NSHomeDirectory(),
        snapshotDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> TeardownSnapshotOutcome {
        guard agent.kind == .claude else { return .nothingToProtect }
        guard isSafeSessionIdPathComponent(agent.sessionId) else { return .unableToProtect }

        guard let transcriptPath = resolveTranscriptPath(
            agent: agent,
            panelKey: panelKey,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) else {
            return .unableToProtect
        }

        if !transcriptHasConversationTurns(atPath: transcriptPath, fileManager: fileManager) {
            return transcriptContainsOnlyNonProtectiveMetadata(atPath: transcriptPath, fileManager: fileManager)
                ? .nothingToProtect
                : .unableToProtect
        }

        guard let directory = snapshotDirectory ?? defaultSnapshotDirectoryURL() else {
            return .unableToProtect
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            pruneOldSnapshots(in: directory, fileManager: fileManager)
            let guardedProcessIdentities = guardedProcessIDs
                .filter { $0 > 0 && $0 <= Int(Int32.max) }
                .sorted()
                .prefix(64)
                .compactMap { AgentPIDProcessIdentity(pid: pid_t($0)) }
            let snapshotURL = directory.appendingPathComponent("\(agent.sessionId)-\(UUID().uuidString).jsonl", isDirectory: false)
            let capturedAt = Date()
            try fileManager.copyItem(atPath: transcriptPath, toPath: snapshotURL.path)
            let copiedSnapshotHasConversation = transcriptHasConversationTurns(
                atPath: snapshotURL.path,
                fileManager: fileManager
            )
            guard copiedSnapshotHasConversation else {
                try? fileManager.removeItem(at: snapshotURL)
                return .unableToProtect
            }
            let unvalidatedSnapshot = TeardownTranscriptSnapshot(
                transcriptPath: transcriptPath,
                snapshotPath: snapshotURL.path
            )
            guard persistRecoveryMetadata(
                for: unvalidatedSnapshot,
                sessionId: agent.sessionId,
                capturedAt: capturedAt,
                guardedProcessIdentities: guardedProcessIdentities
            ) else {
                try? fileManager.removeItem(at: snapshotURL)
                return .unableToProtect
            }
            guard let liveFileVersion = matchingLiveFileVersion(
                transcriptPath,
                snapshotURL.path,
                fileManager: fileManager
            ) else {
                // The live path may have advanced, or an older restore monitor may
                // have won a replace race. Keep the populated copy for recovery in
                // the session's single retained slot so repeated failed attempts
                // replace it instead of accumulating full-transcript copies.
                retainSnapshotForRecovery(
                    unvalidatedSnapshot,
                    sessionId: agent.sessionId,
                    fileManager: fileManager
                )
                return .unableToProtect
            }
            // The first metadata write makes a copy recoverable even when the
            // live-file comparison loses a race. Enrich it only after equality
            // is proven, so a later startup can also discard an unchanged copy.
            _ = persistRecoveryMetadata(
                for: unvalidatedSnapshot,
                sessionId: agent.sessionId,
                capturedAt: capturedAt,
                liveFileVersion: liveFileVersion,
                guardedProcessIdentities: guardedProcessIdentities
            )
            try fileManager.setAttributes([.modificationDate: capturedAt], ofItemAtPath: snapshotURL.path)
            return .snapshot(TeardownTranscriptSnapshot(
                transcriptPath: transcriptPath,
                snapshotPath: snapshotURL.path,
                liveFileVersion: liveFileVersion
            ))
        } catch {
            return .unableToProtect
        }
    }

    @discardableResult
    static func restoreIfClobbered(
        _ snapshot: TeardownTranscriptSnapshot,
        fileManager: FileManager = .default
    ) -> Bool {
        let snapshotDirectory = URL(fileURLWithPath: snapshot.snapshotPath)
            .deletingLastPathComponent()
        guard let lockDescriptor = acquireRecoveryDirectoryLock(in: snapshotDirectory) else {
            return false
        }
        defer { releaseRecoveryDirectoryLock(lockDescriptor) }
        return restoreIfClobberedWhileHoldingDirectoryLock(snapshot, fileManager: fileManager)
    }

    private static func restoreIfClobberedWhileHoldingDirectoryLock(
        _ snapshot: TeardownTranscriptSnapshot,
        fileManager: FileManager
    ) -> Bool {
        let transcriptURL = URL(fileURLWithPath: snapshot.transcriptPath)
        let protectedExists = fileManager.fileExists(atPath: transcriptURL.path)
        let protectedAttributes = try? fileManager.attributesOfItem(atPath: transcriptURL.path)
        let protectedFile = (protectedAttributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        let protectedSize = (protectedAttributes?[.size] as? NSNumber)?.uint64Value
        let protectedModificationDate = protectedAttributes?[.modificationDate] as? Date
        guard transcriptHasConversationTurns(atPath: snapshot.snapshotPath, fileManager: fileManager),
              !transcriptHasConversationTurns(atPath: snapshot.transcriptPath, fileManager: fileManager) else {
            return false
        }
        guard !protectedExists || transcriptContainsOnlyNonProtectiveMetadata(atPath: snapshot.transcriptPath, fileManager: fileManager) else { return false }
        let classifiedAttributes = try? fileManager.attributesOfItem(atPath: transcriptURL.path)
        guard fileManager.fileExists(atPath: transcriptURL.path) == protectedExists,
              (classifiedAttributes?[.systemFileNumber] as? NSNumber)?.uint64Value == protectedFile,
              (classifiedAttributes?[.size] as? NSNumber)?.uint64Value == protectedSize,
              (classifiedAttributes?[.modificationDate] as? Date) == protectedModificationDate else { return false }

        let directoryURL = transcriptURL.deletingLastPathComponent()
        let tempURL = directoryURL.appendingPathComponent(".\(transcriptURL.lastPathComponent).restore-\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: tempURL)
            try fileManager.copyItem(atPath: snapshot.snapshotPath, toPath: tempURL.path)
            try appendLiveStubIfPresent(from: transcriptURL, toRestoreFile: tempURL, fileManager: fileManager)
            let currentAttributes = try? fileManager.attributesOfItem(atPath: transcriptURL.path)
            guard fileManager.fileExists(atPath: transcriptURL.path) == protectedExists,
                  (currentAttributes?[.systemFileNumber] as? NSNumber)?.uint64Value == protectedFile,
                  (currentAttributes?[.size] as? NSNumber)?.uint64Value == protectedSize,
                  (currentAttributes?[.modificationDate] as? Date) == protectedModificationDate,
                  !protectedExists || transcriptContainsOnlyNonProtectiveMetadata(atPath: transcriptURL.path, fileManager: fileManager) else {
                try? fileManager.removeItem(at: tempURL)
                return false
            }
            if protectedExists {
                _ = try fileManager.replaceItemAt(transcriptURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: transcriptURL)
            }
            return true
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    /// Moves a populated snapshot whose live path drifted into the session's
    /// single retained recovery slot. Repeated failed protection attempts
    /// replace the slot instead of accumulating full-transcript copies; the
    /// slot ages out through the regular snapshot pruning. Never touches the
    /// UUID-suffixed snapshots that active restore monitors own.
    static func retainSnapshotForRecovery(
        _ snapshot: TeardownTranscriptSnapshot,
        sessionId: String?,
        fileManager: FileManager = .default
    ) {
        let snapshotURL = URL(fileURLWithPath: snapshot.snapshotPath)
        guard let sessionId, isSafeSessionIdPathComponent(sessionId) else {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
            return
        }
        guard transcriptHasConversationTurns(atPath: snapshotURL.path, fileManager: fileManager) else {
            return
        }
        guard let lockDescriptor = acquireRecoveryDirectoryLock(
            in: snapshotURL.deletingLastPathComponent()
        ) else {
            // The UUID snapshot already carries durable recovery metadata. If a
            // concurrent recovery owns the directory, leaving it in place is
            // safer than racing the shared retained slot.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
            return
        }
        defer { releaseRecoveryDirectoryLock(lockDescriptor) }

        let retainedURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("\(sessionId)-retained.jsonl", isDirectory: false)
        var sourceMetadata = recoveryMetadata(atSnapshotPath: snapshotURL.path)
        let metadataMatchesSnapshot = sourceMetadata.map {
            $0.sessionId == sessionId &&
                ($0.transcriptPath as NSString).standardizingPath ==
                    (snapshot.transcriptPath as NSString).standardizingPath
        } == true
        if !metadataMatchesSnapshot {
            _ = persistRecoveryMetadata(
                for: snapshot,
                sessionId: sessionId,
                capturedAt: snapshotModificationDate(snapshotURL, fileManager: fileManager),
                liveFileVersion: snapshot.liveFileVersion
            )
            sourceMetadata = recoveryMetadata(atSnapshotPath: snapshotURL.path)
        }
        guard let sourceMetadata,
              sourceMetadata.sessionId == sessionId,
              (sourceMetadata.transcriptPath as NSString).standardizingPath ==
                (snapshot.transcriptPath as NSString).standardizingPath else {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
            return
        }
        let capturedAt = sourceMetadata.capturedAt ?? snapshotModificationDate(snapshotURL, fileManager: fileManager)
        guard retainedURL.path != snapshotURL.path else {
            _ = persistRecoveryMetadata(
                for: snapshot,
                sessionId: sessionId,
                capturedAt: capturedAt,
                liveFileVersion: sourceMetadata.liveFileVersion,
                ownerProcessIdentity: sourceMetadata.ownerProcessIdentity,
                guardedProcessIdentities: sourceMetadata.guardedProcesses?.compactMap(\.processIdentity) ?? []
            )
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: retainedURL.path)
            return
        }

        if fileManager.fileExists(atPath: retainedURL.path) {
            guard let retainedMetadata = recoveryMetadata(atSnapshotPath: retainedURL.path),
                  retainedMetadata.sessionId == sessionId,
                  (retainedMetadata.transcriptPath as NSString).standardizingPath ==
                    (sourceMetadata.transcriptPath as NSString).standardizingPath else {
                // Unknown bytes already occupy the single retained slot. Keep
                // both recoverable files instead of destroying either branch.
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
                return
            }
            if file(
                atPath: retainedURL.path,
                stablyContainsPrefixAtPath: snapshotURL.path,
                fileManager: fileManager
            ) {
                // The retained copy already contains every protected byte.
                try? fileManager.removeItem(at: snapshotURL)
                return
            }
            guard capturedAt >= (retainedMetadata.capturedAt ?? .distantPast),
                  file(
                    atPath: snapshotURL.path,
                    stablyContainsPrefixAtPath: retainedURL.path,
                    fileManager: fileManager
                  ) else {
                // Later timestamps alone do not prove append-only ancestry.
                // Preserve divergent branches as separate UUID snapshots.
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
                return
            }
        }

        guard atomicallyRename(snapshotURL, to: retainedURL) else {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
            return
        }
        _ = persistRecoveryMetadata(
            for: TeardownTranscriptSnapshot(
                transcriptPath: snapshot.transcriptPath,
                snapshotPath: retainedURL.path
            ),
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: sourceMetadata.liveFileVersion,
            ownerProcessIdentity: sourceMetadata.ownerProcessIdentity,
            guardedProcessIdentities: sourceMetadata.guardedProcesses?.compactMap(\.processIdentity) ?? []
        )
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: retainedURL.path)
    }

    /// Reconciles snapshots whose in-memory post-teardown monitor disappeared
    /// with the prior app process. Metadata is stored on the snapshot inode, so
    /// the retained-slot rename cannot separate the protected bytes from their
    /// destination path.
    @discardableResult
    static func recoverPendingSnapshots(
        snapshotDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int {
        guard let directory = snapshotDirectory ?? defaultSnapshotDirectoryURL() else {
            return 0
        }
        guard let lockDescriptor = acquireRecoveryDirectoryLock(in: directory) else {
            return 0
        }
        defer { releaseRecoveryDirectoryLock(lockDescriptor) }

        var candidatesByTranscript: [String: [PendingRecoverySnapshot]] = [:]
        for candidate in validatedRecoveryCandidates(in: directory, fileManager: fileManager) {
            let transcriptKey = (candidate.metadata.transcriptPath as NSString).standardizingPath
            candidatesByTranscript[transcriptKey, default: []].append(candidate)
        }
        guard !candidatesByTranscript.isEmpty else { return 0 }

        for key in Array(candidatesByTranscript.keys) {
            candidatesByTranscript[key]?.sort(by: recoveryCandidateIsNewer)
        }
        let orderedTranscriptKeys = rotatedRecoveryTranscriptKeys(
            Array(candidatesByTranscript.keys).sorted(),
            after: recoveryCursor(lockDescriptor: lockDescriptor)
        )
        var nextIndexByTranscript: [String: Int] = [:]
        var selectedByTranscript: [String: [PendingRecoverySnapshot]] = [:]
        var selectedCount = 0
        var lastSelectedTranscript: String?
        while selectedCount < maxStartupRecoverySnapshots {
            var appendedInPass = false
            for transcriptKey in orderedTranscriptKeys where selectedCount < maxStartupRecoverySnapshots {
                let nextIndex = nextIndexByTranscript[transcriptKey, default: 0]
                guard let candidates = candidatesByTranscript[transcriptKey],
                      nextIndex < candidates.count else {
                    continue
                }
                selectedByTranscript[transcriptKey, default: []].append(candidates[nextIndex])
                nextIndexByTranscript[transcriptKey] = nextIndex + 1
                selectedCount += 1
                lastSelectedTranscript = transcriptKey
                appendedInPass = true
            }
            if !appendedInPass { break }
        }
        if let lastSelectedTranscript {
            persistRecoveryCursor(lastSelectedTranscript, lockDescriptor: lockDescriptor)
        }

        var restoredCount = 0
        for transcriptKey in orderedTranscriptKeys {
            guard let newestFirst = selectedByTranscript[transcriptKey] else { continue }
            var newestValidSnapshotWasCommitted = false
            for originalCandidate in newestFirst {
                guard let candidate = claimRecoveryCandidate(originalCandidate) else {
                    continue
                }
                let snapshot = TeardownTranscriptSnapshot(
                    transcriptPath: candidate.metadata.transcriptPath,
                    snapshotPath: candidate.url.path,
                    liveFileVersion: candidate.metadata.liveFileVersion
                )
                guard transcriptHasConversationTurns(
                    atPath: snapshot.snapshotPath,
                    fileManager: fileManager
                ) else {
                    quarantineRecoveryCandidate(candidate, in: directory, fileManager: fileManager)
                    continue
                }
                if newestValidSnapshotWasCommitted {
                    if file(
                        atPath: snapshot.transcriptPath,
                        stablyContainsPrefixAtPath: snapshot.snapshotPath,
                        fileManager: fileManager
                    ) {
                        try? fileManager.removeItem(at: candidate.url)
                    } else {
                        preserveClaimedRecoveryCandidate(
                            candidate,
                            at: originalCandidate.url,
                            fileManager: fileManager
                        )
                    }
                    continue
                }
                if file(
                    atPath: snapshot.transcriptPath,
                    stablyContainsPrefixAtPath: snapshot.snapshotPath,
                    fileManager: fileManager
                ) {
                    try? fileManager.removeItem(at: candidate.url)
                    newestValidSnapshotWasCommitted = true
                    continue
                }
                if restoreIfClobberedWhileHoldingDirectoryLock(snapshot, fileManager: fileManager) {
                    restoredCount += 1
                    try? fileManager.removeItem(at: candidate.url)
                    newestValidSnapshotWasCommitted = true
                    continue
                }
                preserveClaimedRecoveryCandidate(
                    candidate,
                    at: originalCandidate.url,
                    fileManager: fileManager
                )
                // A populated divergent live file means this transcript has
                // branched. Never restore an older candidate over that branch.
                break
            }
        }
        return restoredCount
    }

    static func transcriptCandidates(projectRoot: String, sessionId: String) -> [String] {
        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        let nestedPath = (((projectRoot as NSString).appendingPathComponent(sessionId) as NSString).appendingPathComponent("messages") as NSString).appendingPathComponent("\(sessionId).jsonl")
        return [directPath, nestedPath]
    }

    private static func isSafeSessionIdPathComponent(_ sessionId: String) -> Bool {
        !sessionId.isEmpty && sessionId != "." && sessionId != ".." && !sessionId.contains("/")
    }

    // Mirrors regularNonEmptyFileExists in RestorableAgentSession.swift: an empty
    // recorded/derived file must not shadow a populated transcript elsewhere.
    static func isRegularFile(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return false
        }
        return ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
    }

    private static func directoryExists(atPath path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func recordedTranscriptPath(
        agent: SessionRestorableAgentSnapshot,
        panelKey: AgentHibernationPanelKey?,
        homeDirectory: String,
        fileManager: FileManager
    ) -> (path: String?, isAmbiguous: Bool) {
        let environment = ProcessInfo.processInfo.environment
        let storeURL = RestorableAgentKind.claude.hookStoreFileURL(
            homeDirectory: homeDirectory,
            environment: environment
        )
        let recordData: [Data]
        if let exact = AgentHookSessionRegistryReader.recordData(
            provider: RestorableAgentKind.claude.rawValue,
            sessionID: agent.sessionId,
            legacyURL: storeURL,
            environment: environment,
            fileManager: fileManager
        ) {
            recordData = [exact]
        } else if let records = AgentHookSessionRegistryReader.records(
            provider: RestorableAgentKind.claude.rawValue,
            legacyURL: storeURL,
            environment: environment,
            fileManager: fileManager
        ) {
            recordData = Array(records.values)
        } else {
            return (nil, false)
        }

        var paths: [String] = []
        var seenPaths: Set<String> = []
        for data in recordData {
            guard let record = try? JSONDecoder().decode(
                AgentHibernationTranscriptHookStoreRecord.self,
                from: data
            ) else { continue }
            guard normalized(record.sessionId) == agent.sessionId,
                  panelKey.map({ record.matches(panelKey: $0) }) ?? true,
                  let transcriptPath = normalized(record.transcriptPath) else {
                continue
            }
            let expandedPath = expandTilde(in: transcriptPath, homeDirectory: homeDirectory)
            let standardizedPath = (expandedPath as NSString).standardizingPath
            if seenPaths.insert(standardizedPath).inserted,
               isRegularFile(atPath: expandedPath, fileManager: fileManager) {
                paths.append(expandedPath)
            }
        }
        guard let path = paths.first else { return (nil, false) }
        return paths.count == 1 ? (path, false) : (nil, true)
    }

    static func claudeConfigRoots(
        for agent: SessionRestorableAgentSnapshot,
        homeDirectory: String,
        fileManager: FileManager
    ) -> [String] {
        if let override = normalized(agent.launchCommand?.environment?["CLAUDE_CONFIG_DIR"]) {
            let expanded = expandTilde(in: override, homeDirectory: homeDirectory)
            return [ClaudeConfigDirectoryPath.preferredPath(expanded, fileManager: fileManager, homeDirectory: homeDirectory)]
        }

        var roots: [String] = []
        var seen: Set<String> = []
        func appendRoot(_ path: String) {
            let standardized = (path as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { return }
            roots.append(standardized)
        }

        let accountRoot = (homeDirectory as NSString).appendingPathComponent(".codex-accounts/claude")
        if directoryExists(atPath: accountRoot, fileManager: fileManager),
           let accountDirs = try? fileManager.contentsOfDirectory(atPath: accountRoot) {
            for accountDir in accountDirs.sorted() {
                let accountPath = (accountRoot as NSString).appendingPathComponent(accountDir)
                guard directoryExists(atPath: accountPath, fileManager: fileManager) else { continue }
                appendRoot(accountPath)
            }
        }
        appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
        appendRoot(ClaudeConfigDirectoryPath.preferredPath(
            (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
            fileManager: fileManager,
            homeDirectory: homeDirectory)
        )
        return roots
    }

    private static func persistRecoveryMetadata(
        for snapshot: TeardownTranscriptSnapshot,
        sessionId: String,
        capturedAt: Date,
        liveFileVersion: TeardownTranscriptFileVersion? = nil,
        ownerProcessIdentity: AgentPIDProcessIdentity? = AgentPIDProcessIdentity(pid: getpid()),
        guardedProcessIdentities: [AgentPIDProcessIdentity] = []
    ) -> Bool {
        let ownerRuntimeId = normalized(ProcessInfo.processInfo.environment["CMUX_RUNTIME_ID"])
        guard isSafeSessionIdPathComponent(sessionId),
              let data = try? JSONEncoder().encode(RecoveryMetadata(
                version: 1,
                sessionId: sessionId,
                transcriptPath: snapshot.transcriptPath,
                snapshotPath: snapshot.snapshotPath,
                capturedAt: capturedAt,
                liveFileNumber: liveFileVersion?.fileNumber,
                liveFileSize: liveFileVersion?.size,
                liveFileModificationDate: liveFileVersion?.modificationDate,
                ownerProcessId: ownerProcessIdentity?.pid,
                ownerProcessStartSeconds: ownerProcessIdentity?.startSeconds,
                ownerProcessStartMicroseconds: ownerProcessIdentity?.startMicroseconds,
                ownerRuntimeId: ownerRuntimeId,
                ownerBundleIdentifier: Bundle.main.bundleIdentifier,
                guardedProcesses: Array(guardedProcessIdentities.prefix(64)).map(RecoveryProcessIdentity.init)
              )),
              !data.isEmpty,
              data.count <= maxRecoveryMetadataBytes else {
            return false
        }
        return data.withUnsafeBytes { buffer in
            setxattr(
                snapshot.snapshotPath,
                recoveryMetadataName,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            ) == 0
        }
    }

    private static func recoveryMetadata(atSnapshotPath snapshotPath: String) -> RecoveryMetadata? {
        let byteCount = getxattr(snapshotPath, recoveryMetadataName, nil, 0, 0, 0)
        guard byteCount > 0, byteCount <= maxRecoveryMetadataBytes else { return nil }
        var data = Data(count: byteCount)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            getxattr(
                snapshotPath,
                recoveryMetadataName,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        guard bytesRead == byteCount else { return nil }
        return try? JSONDecoder().decode(RecoveryMetadata.self, from: data)
    }

    private static func snapshotModificationDate(
        _ snapshotURL: URL,
        fileManager: FileManager
    ) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: snapshotURL.path)
        return attributes?[.modificationDate] as? Date ?? Date()
    }

    private static func snapshotFilenameMatchesSession(_ snapshotURL: URL, sessionId: String) -> Bool {
        let filename = snapshotURL.lastPathComponent
        return filename == "\(sessionId)-retained.jsonl" ||
            (filename.hasPrefix("\(sessionId)-") && filename.hasSuffix(".jsonl"))
    }

    private static func validatedRecoveryCandidates(
        in directory: URL,
        fileManager: FileManager
    ) -> [PendingRecoverySnapshot] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        let standardizedSnapshotDirectory = (directory.path as NSString).standardizingPath
        let latestAllowedCaptureDate = Date().addingTimeInterval(5 * 60)
        var candidates: [PendingRecoverySnapshot] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let metadata = recoveryMetadata(atSnapshotPath: url.path),
                  metadata.version == 1,
                  isSafeSessionIdPathComponent(metadata.sessionId),
                  snapshotFilenameMatchesSession(url, sessionId: metadata.sessionId),
                  metadata.transcriptPath.hasPrefix("/"),
                  !metadata.transcriptPath.contains("\0"),
                  (metadata.transcriptPath as NSString).standardizingPath !=
                    (url.path as NSString).standardizingPath else {
                continue
            }
            let transcriptKey = (metadata.transcriptPath as NSString).standardizingPath
            guard transcriptKey != standardizedSnapshotDirectory,
                  !transcriptKey.hasPrefix(standardizedSnapshotDirectory + "/"),
                  transcriptDestinationIsRegularOrMissing(
                    metadata.transcriptPath,
                    fileManager: fileManager
                  ),
                  !recoveryMetadataHasLiveOwner(metadata) else {
                continue
            }
            let modificationDate = values.contentModificationDate ?? .distantPast
            let capturedAt: Date
            if let metadataCapturedAt = metadata.capturedAt {
                guard metadataCapturedAt <= latestAllowedCaptureDate else { continue }
                capturedAt = metadataCapturedAt
            } else {
                guard modificationDate <= latestAllowedCaptureDate else { continue }
                capturedAt = modificationDate
            }
            candidates.append(PendingRecoverySnapshot(
                url: url,
                metadata: metadata,
                capturedAt: capturedAt,
                modificationDate: modificationDate
            ))
        }
        return candidates
    }

    private static func recoveryCandidateIsNewer(
        _ lhs: PendingRecoverySnapshot,
        _ rhs: PendingRecoverySnapshot
    ) -> Bool {
        if lhs.capturedAt != rhs.capturedAt {
            return lhs.capturedAt > rhs.capturedAt
        }
        if lhs.modificationDate != rhs.modificationDate {
            return lhs.modificationDate > rhs.modificationDate
        }
        return lhs.url.path > rhs.url.path
    }

    private static func recoveryMetadataHasLiveOwner(_ metadata: RecoveryMetadata) -> Bool {
        if let ownerIdentity = metadata.ownerProcessIdentity,
           ownerIdentity.pid != getpid(),
           AgentPIDProcessIdentity(pid: ownerIdentity.pid) == ownerIdentity {
            return true
        }
        return metadata.guardedProcesses?.prefix(64).contains { guarded in
            guard let identity = guarded.processIdentity else { return false }
            return AgentPIDProcessIdentity(pid: identity.pid) == identity
        } == true
    }

    private static func transcriptDestinationIsRegularOrMissing(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: path) else { return true }
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let fileType = attributes[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeRegular
    }

    private static func rotatedRecoveryTranscriptKeys(
        _ sortedKeys: [String],
        after cursor: String?
    ) -> [String] {
        guard let cursor,
              let cursorIndex = sortedKeys.firstIndex(of: cursor),
              cursorIndex + 1 < sortedKeys.count else {
            return sortedKeys
        }
        return Array(sortedKeys[(cursorIndex + 1)...]) + Array(sortedKeys[...cursorIndex])
    }

    private static func acquireRecoveryDirectoryLock(in directory: URL) -> Int32? {
        let lockURL = directory.appendingPathComponent(recoveryLockFilename, isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        return descriptor
    }

    private static func releaseRecoveryDirectoryLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private static func recoveryCursor(lockDescriptor: Int32) -> String? {
        let handle = FileHandle(fileDescriptor: lockDescriptor, closeOnDealloc: false)
        do {
            try handle.seek(toOffset: 0)
            guard let data = try handle.read(upToCount: maxRecoveryCursorBytes + 1),
                  !data.isEmpty,
                  data.count <= maxRecoveryCursorBytes,
                  let value = String(data: data, encoding: .utf8),
                  !value.contains("\0") else {
                return nil
            }
            return value
        } catch {
            return nil
        }
    }

    private static func persistRecoveryCursor(_ cursor: String, lockDescriptor: Int32) {
        guard let data = cursor.data(using: .utf8),
              !data.isEmpty,
              data.count <= maxRecoveryCursorBytes else {
            return
        }
        let handle = FileHandle(fileDescriptor: lockDescriptor, closeOnDealloc: false)
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            return
        }
    }

    private static func claimRecoveryCandidate(
        _ candidate: PendingRecoverySnapshot
    ) -> PendingRecoverySnapshot? {
        let claimedURL = candidate.url.deletingLastPathComponent()
            .appendingPathComponent(
                "\(candidate.metadata.sessionId)-processing-\(UUID().uuidString).jsonl",
                isDirectory: false
            )
        guard atomicallyRename(candidate.url, to: claimedURL) else { return nil }
        return PendingRecoverySnapshot(
            url: claimedURL,
            metadata: candidate.metadata,
            capturedAt: candidate.capturedAt,
            modificationDate: candidate.modificationDate
        )
    }

    private static func preserveClaimedRecoveryCandidate(
        _ candidate: PendingRecoverySnapshot,
        at originalURL: URL,
        fileManager: FileManager
    ) {
        let preservedURL: URL
        if !fileManager.fileExists(atPath: originalURL.path),
           atomicallyRename(candidate.url, to: originalURL) {
            preservedURL = originalURL
        } else {
            preservedURL = candidate.url
        }
        _ = persistRecoveryMetadata(
            for: TeardownTranscriptSnapshot(
                transcriptPath: candidate.metadata.transcriptPath,
                snapshotPath: preservedURL.path
            ),
            sessionId: candidate.metadata.sessionId,
            capturedAt: candidate.capturedAt,
            liveFileVersion: candidate.metadata.liveFileVersion,
            guardedProcessIdentities: candidate.metadata.guardedProcesses?.compactMap(\.processIdentity) ?? []
        )
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: preservedURL.path)
    }

    private static func quarantineRecoveryCandidate(
        _ candidate: PendingRecoverySnapshot,
        in directory: URL,
        fileManager: FileManager
    ) {
        let quarantineDirectory = directory.appendingPathComponent(
            ".recovery-quarantine",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let quarantineURL = quarantineDirectory.appendingPathComponent(
                "\(candidate.url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).jsonl",
                isDirectory: false
            )
            guard atomicallyRename(candidate.url, to: quarantineURL) else { return }
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: quarantineURL.path)
        } catch {
            return
        }
    }

    private static func atomicallyRename(_ source: URL, to destination: URL) -> Bool {
        Darwin.rename(source.path, destination.path) == 0
    }

    private static func defaultSnapshotDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-transcript-teardown-snapshots", isDirectory: true)
    }

    private static func pruneOldSnapshots(in directory: URL, fileManager: FileManager) {
        guard var urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let quarantineDirectory = directory.appendingPathComponent(
            ".recovery-quarantine",
            isDirectory: true
        )
        if let quarantined = try? fileManager.contentsOfDirectory(
            at: quarantineDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) {
            urls.append(contentsOf: quarantined)
        }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map({ $0 < cutoff }) == true else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    static func transcriptContainsOnlyNonProtectiveMetadata(
        atPath path: String,
        fileManager: FileManager,
        maxScannedLineBytes: Int = Self.maxScannedLineBytes
    ) -> Bool {
        boundedTranscriptContainsOnlyNonProtectiveMetadata(
            atPath: path,
            fileManager: fileManager,
            maxScannedLineBytes: maxScannedLineBytes
        )
    }

    private static func appendLiveStubIfPresent(
        from stubURL: URL,
        toRestoreFile restoreURL: URL,
        fileManager: FileManager
    ) throws {
        guard isRegularFile(atPath: stubURL.path, fileManager: fileManager) else { return }

        let output = try FileHandle(forUpdating: restoreURL)
        defer { try? output.close() }
        let endOffset = try output.seekToEnd()
        let trimmedOffset = try offsetByTrimmingTrailingNewlines(handle: output, endOffset: endOffset)
        try output.truncate(atOffset: trimmedOffset)
        try output.seekToEnd()
        try output.write(contentsOf: Data([10]))

        let input = try FileHandle(forReadingFrom: stubURL)
        defer { try? input.close() }
        var skippingLeadingNewlines = true
        while let chunk = try input.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            var bytes = chunk[chunk.startIndex..<chunk.endIndex]
            if skippingLeadingNewlines {
                guard let firstContentIndex = bytes.firstIndex(where: { $0 != 10 && $0 != 13 }) else {
                    continue
                }
                bytes = chunk[firstContentIndex..<chunk.endIndex]
                skippingLeadingNewlines = false
            }
            try output.write(contentsOf: bytes)
        }
    }

    private static func offsetByTrimmingTrailingNewlines(handle: FileHandle, endOffset: UInt64) throws -> UInt64 {
        var remainingEnd = endOffset
        while remainingEnd > 0 {
            let readSize = min(UInt64(64 * 1024), remainingEnd)
            let startOffset = remainingEnd - readSize
            try handle.seek(toOffset: startOffset)
            guard let data = try handle.read(upToCount: Int(readSize)),
                  !data.isEmpty else {
                return remainingEnd
            }
            var index = data.endIndex
            while index > data.startIndex {
                let previous = data.index(before: index)
                let byte = data[previous]
                if byte != 10 && byte != 13 {
                    return startOffset + UInt64(data.distance(from: data.startIndex, to: index))
                }
                index = previous
            }
            remainingEnd = startOffset
        }
        return 0
    }

    static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func expandTilde(in path: String, homeDirectory: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = (homeDirectory as NSString).expandingTildeInPath
        guard path != "~" else { return home }
        return (home as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}
