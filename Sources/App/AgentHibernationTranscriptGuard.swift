import CMUXAgentLaunch
import Darwin
import Foundation
import os

enum AgentHibernationTranscriptGuard {
    static let restoreCheckDelaysSeconds: [UInt64] = [20, 60, 180, 600]
    private static let maxScannedLineBytes = 16 * 1024 * 1024
    private static let recoveryMetadataName = "com.cmux.agent-transcript-recovery"
    private static let maxRecoveryMetadataBytes = 64 * 1024
    private static let maxStartupRecoverySnapshots = 256
    private static let maxStartupRecoveryDirectoryEntries = 1_024
    private static let maxStartupRecoveryCandidateMetadataBytes =
        maxStartupRecoverySnapshots * maxRecoveryMetadataBytes
    private static let maxStartupRecoveryCandidateContentBytes: UInt64 =
        512 * 1_024 * 1_024
    private static let maxStartupRecoveryInvalidMovesPerLaunch = 1_024
    private static let maxStartupRecoveryProcessIdentityProbes = 2_048
    // Protecting larger transcripts would make every copy and proof
    // proportional to unbounded user-controlled input. Claude histories above
    // 256 MiB fail hibernation closed and remain live.
    static let maximumProtectedTranscriptBytes: UInt64 = 256 * 1_024 * 1_024
    // Recovery authority is never deleted merely because it is old. Bound new
    // admission instead, so repeated divergent branches cannot consume the
    // user's disk without limit while every existing branch remains intact.
    private static let maximumRecoveryStorageFileCount = 1_024
    private static let maximumRecoveryStorageBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
    private static let recoveryLockFilename = ".agent-transcript-recovery.lock"
    private static let maxRecoveryCursorBytes = 16 * 1024
    private static let maximumLiveStubBytes: UInt64 = 16 * 1_024 * 1_024
    private static let recoveryLockWaitQueue = DispatchQueue(
        label: "com.cmux.agent-hibernation.recovery-lock-wait",
        qos: .utility
    )
    private static let atomicSwapCapabilityCache = OSAllocatedUnfairLock(
        initialState: [UInt64: Bool]()
    )

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

    private struct RecoveryMetadata: Codable, Equatable {
        let version: Int
        let sessionId: String
        let transcriptPath: String
        let snapshotPath: String?
        let candidateId: String?
        let candidateState: String?
        let externalCandidatePath: String?
        let externalFileDevice: UInt64?
        let externalFileNumber: UInt64?
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
        let hasUncapturedGuardedProcesses: Bool?

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
        let contentURL: URL
        let authorityVersion: TeardownTranscriptFileVersion
        let contentVersion: TeardownTranscriptFileVersion
        let metadata: RecoveryMetadata
        let metadataByteCount: Int
        let contentByteCount: UInt64
        let capturedAt: Date
        let modificationDate: Date
    }

    private struct RecoveryMetadataEnvelope {
        let metadata: RecoveryMetadata
        let byteCount: Int
    }

    private struct RecoveryOwnerRuntimeMetadata {
        let runtimeId: String?
        let bundleIdentifier: String?
    }

    private struct RecoveryCursorState: Codable {
        var transcriptPath: String?
    }

    private enum CachedRecoveryProcessIdentity {
        case missing
        case present(AgentPIDProcessIdentity)
    }

    private enum RecoveryOwnerState: Equatable {
        case retired
        case live
        case unknown
    }

    private struct RecoveryProcessProbeBudget {
        var remaining: Int
        var cache: [pid_t: CachedRecoveryProcessIdentity] = [:]

        mutating func identity(
            for processID: pid_t
        ) -> (known: Bool, identity: AgentPIDProcessIdentity?) {
            if let cached = cache[processID] {
                switch cached {
                case .missing:
                    return (true, nil)
                case .present(let identity):
                    return (true, identity)
                }
            }
            guard remaining > 0 else { return (false, nil) }
            remaining -= 1
            let identity = AgentPIDProcessIdentity(pid: processID)
            cache[processID] = identity.map(CachedRecoveryProcessIdentity.present)
                ?? .missing
            return (true, identity)
        }
    }

    private struct RecoveryStorageFileIdentity: Hashable {
        let device: UInt64
        let fileNumber: UInt64

        init(_ status: stat) {
            device = UInt64(status.st_dev)
            fileNumber = UInt64(status.st_ino)
        }
    }

    private struct RecoveryCandidateScan {
        let candidates: [PendingRecoverySnapshot]
        let budgetBlockedTranscriptPaths: Set<String>
        let invalidEntries: [URL]
        let examinedEntries: Int
        let reachedEnd: Bool
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
        fileManager: FileManager = .default,
        maximumGuardedProcessIdentities: Int = 64,
        maximumRecoveryStorageFileCount: Int = Self.maximumRecoveryStorageFileCount,
        maximumRecoveryStorageBytes: UInt64 = Self.maximumRecoveryStorageBytes,
        recoveryMetadataOwnerProcessIdentity: AgentPIDProcessIdentity? = AgentPIDProcessIdentity(
            pid: getpid()
        )
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
            guard ensurePrivateRecoveryDirectory(
                at: directory,
                createIfMissing: true,
                fileManager: fileManager
            ) else {
                return .unableToProtect
            }
            guard let sourceVersion = stableRegularFileVersion(
                atPath: transcriptPath,
                fileManager: fileManager
            ), sourceVersion.size <= maximumProtectedTranscriptBytes,
                  let admissionLock = acquireRecoveryDirectoryLockSynchronously(
                    in: directory
                  ) else {
                return .unableToProtect
            }
            pruneOldSnapshots(in: directory, fileManager: fileManager)
            let canAdmitCapture = recoveryStorageCanAdmit(
                in: directory,
                additionalFileCount: 1,
                additionalBytes: sourceVersion.size,
                maximumFileCount: maximumRecoveryStorageFileCount,
                maximumBytes: maximumRecoveryStorageBytes
            )
            releaseRecoveryDirectoryLock(admissionLock)
            guard canAdmitCapture else { return .unableToProtect }
            let guardedProcessCapture = capturedGuardedProcessIdentities(
                from: guardedProcessIDs,
                maximumIdentities: max(0, maximumGuardedProcessIdentities)
            )
            let guardedProcessIdentities = guardedProcessCapture.identities
            let hasUncapturedGuardedProcesses = guardedProcessCapture.hasUncaptured
            let candidateId = UUID().uuidString
            let snapshotURL = directory.appendingPathComponent(
                "\(agent.sessionId)-\(candidateId).jsonl",
                isDirectory: false
            )
            let stagingURL = directory.appendingPathComponent(
                ".\(agent.sessionId)-capture-\(candidateId).tmp",
                isDirectory: false
            )
            let capturedAt = Date()
            guard !hasUncapturedGuardedProcesses else {
                return .unableToProtect
            }
            guard copyStableRegularFileBounded(
                from: transcriptPath,
                to: stagingURL.path,
                maximumBytes: maximumProtectedTranscriptBytes,
                fileManager: fileManager
            ) else {
                return .unableToProtect
            }
            let copiedSnapshotHasConversation = transcriptHasConversationTurns(
                atPath: stagingURL.path,
                fileManager: fileManager
            )
            guard copiedSnapshotHasConversation else {
                try? fileManager.removeItem(at: stagingURL)
                return .unableToProtect
            }
            let stagedSnapshot = TeardownTranscriptSnapshot(
                transcriptPath: transcriptPath,
                snapshotPath: stagingURL.path,
                guardedProcessIdentities: guardedProcessIdentities,
                hasUncapturedGuardedProcesses: hasUncapturedGuardedProcesses
            )
            guard persistRecoveryMetadata(
                for: stagedSnapshot,
                sessionId: agent.sessionId,
                capturedAt: capturedAt,
                ownerProcessIdentity: recoveryMetadataOwnerProcessIdentity,
                guardedProcessIdentities: guardedProcessIdentities,
                hasUncapturedGuardedProcesses: hasUncapturedGuardedProcesses,
                candidateId: candidateId
            ) else {
                try? fileManager.removeItem(at: stagingURL)
                return .unableToProtect
            }
            guard synchronizeRegularFileAndContainingDirectory(
                atPath: stagingURL.path
            ) else {
                return .unableToProtect
            }
            // Copies run concurrently, but namespace admission is serialized.
            // Recount complete staging files under the directory lock so a
            // transcript that grew during copying, or a concurrent capture,
            // can never publish beyond the durable quota.
            guard let commitLock = acquireRecoveryDirectoryLockSynchronously(
                in: directory
            ) else {
                return .unableToProtect
            }
            var releaseCommitLock = true
            defer {
                if releaseCommitLock {
                    releaseRecoveryDirectoryLock(commitLock)
                }
            }
            guard recoveryStorageCanAdmit(
                in: directory,
                additionalFileCount: 0,
                additionalBytes: 0,
                maximumFileCount: maximumRecoveryStorageFileCount,
                maximumBytes: maximumRecoveryStorageBytes
            ) else {
                if let stagingVersion = stableRegularFileVersion(
                    atPath: stagingURL.path,
                    fileManager: fileManager
                ) {
                    _ = durablyRemoveRecoverySnapshot(
                        atPath: stagingURL.path,
                        expectedSnapshotVersion: stagingVersion
                    )
                }
                return .unableToProtect
            }
            guard atomicallyRename(stagingURL, to: snapshotURL),
                  synchronizeRegularFileAndContainingDirectory(
                    atPath: snapshotURL.path
                  ) else {
                // Keep a complete staged capture. Deleting it here would lose
                // the only protected copy if teardown already clobbered live.
                return .unableToProtect
            }
            let unvalidatedSnapshot = TeardownTranscriptSnapshot(
                transcriptPath: transcriptPath,
                snapshotPath: snapshotURL.path,
                guardedProcessIdentities: guardedProcessIdentities,
                hasUncapturedGuardedProcesses: hasUncapturedGuardedProcesses
            )
            guard let liveFileVersion = matchingLiveFileVersion(
                transcriptPath,
                snapshotURL.path,
                fileManager: fileManager
            ) else {
                // The live path may have advanced, or an older restore monitor may
                // have won a replace race. Keep the populated copy for recovery in
                // the session's single retained slot so repeated failed attempts
                // replace it instead of accumulating full-transcript copies.
                releaseRecoveryDirectoryLock(commitLock)
                releaseCommitLock = false
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
                ownerProcessIdentity: recoveryMetadataOwnerProcessIdentity,
                guardedProcessIdentities: guardedProcessIdentities,
                hasUncapturedGuardedProcesses: hasUncapturedGuardedProcesses,
                candidateId: candidateId
            )
            try fileManager.setAttributes([.modificationDate: capturedAt], ofItemAtPath: snapshotURL.path)
            guard synchronizeRegularFileAndContainingDirectory(
                atPath: snapshotURL.path
            ) else {
                return .unableToProtect
            }
            return .snapshot(TeardownTranscriptSnapshot(
                transcriptPath: transcriptPath,
                snapshotPath: snapshotURL.path,
                liveFileVersion: liveFileVersion,
                guardedProcessIdentities: guardedProcessIdentities,
                hasUncapturedGuardedProcesses: hasUncapturedGuardedProcesses
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
        return restoreIfClobberedWhileHoldingDirectoryLock(
            snapshot,
            fileManager: fileManager
        )
    }

    private static func restoreIfClobberedWhileHoldingDirectoryLock(
        _ snapshot: TeardownTranscriptSnapshot,
        fileManager: FileManager
    ) -> Bool {
        let transcriptURL = URL(fileURLWithPath: snapshot.transcriptPath)
        var protectedStatus = stat()
        let protectedStatusResult = lstat(transcriptURL.path, &protectedStatus)
        let protectedExists = protectedStatusResult == 0
        guard protectedExists || errno == ENOENT else { return false }
        if protectedExists {
            guard protectedStatus.st_mode & S_IFMT == S_IFREG,
                  protectedStatus.st_uid == geteuid(),
                  protectedStatus.st_nlink == 1 else {
                return false
            }
        }
        guard transcriptHasConversationTurns(
            atPath: snapshot.snapshotPath,
            fileManager: fileManager
        ) else { return false }
        let liveIsProtectedPrefix = protectedExists && file(
            atPath: snapshot.snapshotPath,
            stablyContainsPrefixAtPath: snapshot.transcriptPath,
            fileManager: fileManager
        )
        let liveIsMetadataOnly = protectedExists
            && !transcriptHasConversationTurns(
                atPath: snapshot.transcriptPath,
                fileManager: fileManager
            )
            && transcriptContainsOnlyNonProtectiveMetadata(
                atPath: snapshot.transcriptPath,
                fileManager: fileManager
            )
        guard !protectedExists || liveIsProtectedPrefix || liveIsMetadataOnly else {
            return false
        }
        guard pathStillMatches(
            transcriptURL.path,
            expectedExists: protectedExists,
            expectedStatus: protectedStatus
        ) else { return false }

        let directoryURL = transcriptURL.deletingLastPathComponent()
        let displacementCandidateId = UUID().uuidString
        let tempURL = directoryURL.appendingPathComponent(
            ".\(transcriptURL.lastPathComponent).cmux-recovery-\(displacementCandidateId).jsonl",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if protectedExists,
               !volumeSupportsAtomicSwap(in: directoryURL) {
                return false
            }
            guard let stagingAuthority = prepareExternalRestoreStagingAuthority(
                transcriptURL: transcriptURL,
                externalURL: tempURL,
                protectedSnapshot: snapshot,
                candidateId: displacementCandidateId,
                fileManager: fileManager
            ) else {
                return false
            }
            var shouldCleanStagingAuthority = true
            defer {
                if shouldCleanStagingAuthority {
                    _ = cleanupExternalRestoreStagingAuthority(
                        at: stagingAuthority.pointerURL,
                        fileManager: fileManager
                    )
                }
                Darwin.close(stagingAuthority.externalDescriptor)
            }
            guard copyStableRegularFileBounded(
                from: snapshot.snapshotPath,
                toExistingDescriptor: stagingAuthority.externalDescriptor,
                expectedDestinationPath: tempURL.path,
                maximumBytes: maximumProtectedTranscriptBytes,
                fileManager: fileManager
            ) else {
                return false
            }
            if liveIsMetadataOnly {
                try appendLiveStubIfPresent(
                    from: transcriptURL,
                    toRestoreFile: tempURL,
                    fileManager: fileManager
                )
            }
            guard synchronizeRegularFileAndContainingDirectory(atPath: tempURL.path) else {
                return false
            }
            guard let tempVersion = stableRegularFileVersion(
                atPath: tempURL.path,
                fileManager: fileManager
            ) else { return false }
            guard pathStillMatches(
                    transcriptURL.path,
                    expectedExists: protectedExists,
                    expectedStatus: protectedStatus
                  ),
                  !protectedExists || (liveIsProtectedPrefix
                    ? file(
                        atPath: snapshot.snapshotPath,
                        stablyContainsPrefixAtPath: transcriptURL.path,
                        fileManager: fileManager
                      )
                    : transcriptContainsOnlyNonProtectiveMetadata(
                        atPath: transcriptURL.path,
                        fileManager: fileManager
                      )) else {
                return false
            }
            if protectedExists {
                guard let displacedAuthority = prepareAtomicSwapDisplacementAuthority(
                    transcriptURL: transcriptURL,
                    externalURL: tempURL,
                    protectedSnapshot: snapshot,
                    expectedLiveStatus: protectedStatus,
                    candidateId: displacementCandidateId,
                    fileManager: fileManager
                ) else {
                    return false
                }
                guard renamex_np(
                    tempURL.path,
                    transcriptURL.path,
                    UInt32(RENAME_SWAP)
                ) == 0 else {
                    _ = durablyRemoveRecoverySnapshot(
                        atPath: displacedAuthority.authorityURL.path,
                        expectedSnapshotVersion: displacedAuthority.authorityVersion
                    )
                    return false
                }
                // The namespace swap is atomic: live now names the complete
                // composite while temp names the exact displaced inode. From
                // this point temp is durable recovery content, never scratch.
                shouldCleanStagingAuthority = false
                var displacedStatus = stat()
                guard lstat(tempURL.path, &displacedStatus) == 0,
                      sameRegularFileIdentity(
                        displacedStatus,
                        displacedAuthority.contentIdentity
                      ),
                      stableRegularFileVersion(
                        atPath: transcriptURL.path,
                        fileManager: fileManager
                      ) == tempVersion,
                      synchronizeRegularFileAndContainingDirectory(
                        atPath: transcriptURL.path
                      ),
                      synchronizeRegularFileAndContainingDirectory(
                        atPath: tempURL.path
                      ),
                      synchronizeRegularFileAndContainingDirectory(
                        atPath: displacedAuthority.authorityURL.path
                      ) else {
                    return false
                }
                _ = fremovexattr(
                    stagingAuthority.externalDescriptor,
                    recoveryMetadataName,
                    0
                )
                _ = fsync(stagingAuthority.externalDescriptor)
                _ = durablyRemoveRecoverySnapshot(
                    atPath: stagingAuthority.pointerURL.path,
                    expectedSnapshotVersion: stagingAuthority.pointerVersion
                )
            } else {
                // RENAME_EXCL is the missing-path CAS. A newly created live
                // branch wins and remains untouched.
                guard renamex_np(
                    tempURL.path,
                    transcriptURL.path,
                    UInt32(RENAME_EXCL)
                ) == 0 else {
                    return false
                }
                shouldCleanStagingAuthority = false
                _ = fremovexattr(
                    stagingAuthority.externalDescriptor,
                    recoveryMetadataName,
                    0
                )
                _ = fsync(stagingAuthority.externalDescriptor)
                _ = durablyRemoveRecoverySnapshot(
                    atPath: stagingAuthority.pointerURL.path,
                    expectedSnapshotVersion: stagingAuthority.pointerVersion
                )
            }
            return synchronizeRegularFileAndContainingDirectory(atPath: transcriptURL.path)
        } catch {
            return false
        }
    }

    struct DisplacedTranscriptAuthority {
        let authorityURL: URL
        let authorityVersion: TeardownTranscriptFileVersion
        let contentURL: URL
        let contentIdentity: stat
    }

    private struct ExternalRestoreStagingAuthority {
        let pointerURL: URL
        let pointerVersion: TeardownTranscriptFileVersion
        let externalURL: URL
        let externalDescriptor: Int32
    }

    private static func prepareExternalRestoreStagingAuthority(
        transcriptURL: URL,
        externalURL: URL,
        protectedSnapshot: TeardownTranscriptSnapshot,
        candidateId: String,
        fileManager: FileManager
    ) -> ExternalRestoreStagingAuthority? {
        let sourceMetadata = recoveryMetadata(
            atSnapshotPath: protectedSnapshot.snapshotPath
        )
        let sessionId = sourceMetadata.flatMap {
            isSafeSessionIdPathComponent($0.sessionId) ? $0.sessionId : nil
        } ?? "staging-\(UUID().uuidString)"
        let recoveryDirectory = URL(
            fileURLWithPath: protectedSnapshot.snapshotPath
        ).deletingLastPathComponent()
        let pointerURL = recoveryDirectory.appendingPathComponent(
            "\(sessionId)-staging-\(candidateId).jsonl",
            isDirectory: false
        )
        let guardedProcesses = sourceMetadata?.guardedProcesses?
            .compactMap(\.processIdentity) ?? protectedSnapshot.guardedProcessIdentities
        let hasUncaptured = sourceMetadata?.hasUncapturedGuardedProcesses
            ?? protectedSnapshot.hasUncapturedGuardedProcesses
        let ownerIdentity = AgentPIDProcessIdentity(pid: getpid())
        let pointerSnapshot = TeardownTranscriptSnapshot(
            transcriptPath: protectedSnapshot.transcriptPath,
            snapshotPath: pointerURL.path,
            liveFileVersion: protectedSnapshot.liveFileVersion,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured
        )
        let capturedAt = Date()
        guard createRecoveryPointerFile(at: pointerURL) else { return nil }
        var keepPointer = false
        var externalDescriptor: Int32 = -1
        defer {
            if !keepPointer {
                if externalDescriptor >= 0 {
                    Darwin.close(externalDescriptor)
                    _ = Darwin.unlink(externalURL.path)
                    _ = synchronizeContainingDirectory(atPath: externalURL.path)
                }
                _ = durablyRemoveRecoverySnapshot(atPath: pointerURL.path)
            }
        }
        guard persistRecoveryMetadata(
                for: pointerSnapshot,
                sessionId: sessionId,
                capturedAt: capturedAt,
                liveFileVersion: protectedSnapshot.liveFileVersion,
                ownerProcessIdentity: ownerIdentity,
                guardedProcessIdentities: guardedProcesses,
                hasUncapturedGuardedProcesses: hasUncaptured,
                candidateId: candidateId,
                candidateState: "external-staging-pending",
                externalCandidatePath: externalURL.path
              ),
              synchronizeRegularFileAndContainingDirectory(
                atPath: pointerURL.path
              ) else {
            return nil
        }
        externalDescriptor = open(
            externalURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard externalDescriptor >= 0 else { return nil }
        var externalStatus = stat()
        guard fstat(externalDescriptor, &externalStatus) == 0,
              externalStatus.st_mode & S_IFMT == S_IFREG,
              externalStatus.st_uid == geteuid(),
              externalStatus.st_nlink == 1,
              externalStatus.st_size == 0,
              path(externalURL.path, names: externalStatus) else {
            return nil
        }
        let externalDevice = UInt64(externalStatus.st_dev)
        let externalFile = UInt64(externalStatus.st_ino)
        let externalSnapshot = TeardownTranscriptSnapshot(
            transcriptPath: protectedSnapshot.transcriptPath,
            snapshotPath: externalURL.path,
            liveFileVersion: protectedSnapshot.liveFileVersion,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured
        )
        guard persistRecoveryMetadata(
            for: pointerSnapshot,
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: protectedSnapshot.liveFileVersion,
            ownerProcessIdentity: ownerIdentity,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured,
            candidateId: candidateId,
            candidateState: "external-staging",
            externalCandidatePath: externalURL.path,
            externalFileDevice: externalDevice,
            externalFileNumber: externalFile
        ), synchronizeRegularFileAndContainingDirectory(atPath: pointerURL.path),
           persistRecoveryMetadata(
            for: externalSnapshot,
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: protectedSnapshot.liveFileVersion,
            ownerProcessIdentity: ownerIdentity,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured,
            candidateId: candidateId,
            candidateState: "external-staging",
            externalCandidatePath: externalURL.path,
            externalFileDevice: externalDevice,
            externalFileNumber: externalFile,
            destinationDescriptor: externalDescriptor
           ), synchronizeContainingDirectory(atPath: externalURL.path),
           let pointerVersion = stableRegularFileVersion(
            atPath: pointerURL.path,
            fileManager: fileManager
           ) else {
            return nil
        }
        keepPointer = true
        return ExternalRestoreStagingAuthority(
            pointerURL: pointerURL,
            pointerVersion: pointerVersion,
            externalURL: externalURL,
            externalDescriptor: externalDescriptor
        )
    }

    @discardableResult
    private static func cleanupExternalRestoreStagingAuthority(
        at pointerURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let metadata = recoveryMetadata(atSnapshotPath: pointerURL.path),
              metadata.version == 2,
              (metadata.candidateState == "external-staging"
                || metadata.candidateState == "external-staging-pending"),
              isSafeSessionIdPathComponent(metadata.sessionId),
              let candidateId = metadata.candidateId,
              UUID(uuidString: candidateId) != nil,
              let externalPath = metadata.externalCandidatePath,
              externalPath.hasPrefix("/"),
              !externalPath.contains("\0"),
              metadata.transcriptPath.hasPrefix("/"),
              !metadata.transcriptPath.contains("\0") else {
            return false
        }
        let transcriptURL = URL(fileURLWithPath: metadata.transcriptPath)
        let expectedExternalURL = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(transcriptURL.lastPathComponent).cmux-recovery-\(candidateId).jsonl",
                isDirectory: false
            )
        guard (externalPath as NSString).standardizingPath
                == (expectedExternalURL.path as NSString).standardizingPath,
              let pointerVersion = stableRegularFileVersion(
                atPath: pointerURL.path,
                fileManager: fileManager
              ) else {
            return false
        }
        var externalStatus = stat()
        if lstat(externalPath, &externalStatus) == 0 {
            let exactStagingInode: Bool
            if metadata.candidateState == "external-staging-pending" {
                exactStagingInode = metadata.externalFileDevice == nil
                    && metadata.externalFileNumber == nil
                    && externalStatus.st_mode & S_IFMT == S_IFREG
                    && externalStatus.st_uid == geteuid()
                    && externalStatus.st_nlink == 1
                    && externalStatus.st_size == 0
            } else {
                exactStagingInode = UInt64(externalStatus.st_dev)
                        == metadata.externalFileDevice
                    && UInt64(externalStatus.st_ino)
                        == metadata.externalFileNumber
                    && externalStatus.st_mode & S_IFMT == S_IFREG
                    && externalStatus.st_uid == geteuid()
                    && externalStatus.st_nlink == 1
            }
            if exactStagingInode,
               let externalVersion = stableRegularFileVersion(
                atPath: externalPath,
                fileManager: fileManager
               ) {
                _ = durablyRemoveRecoverySnapshot(
                    atPath: externalPath,
                    expectedSnapshotVersion: externalVersion
                )
            }
        } else if errno != ENOENT {
            return false
        }
        return durablyRemoveRecoverySnapshot(
            atPath: pointerURL.path,
            expectedSnapshotVersion: pointerVersion
        )
    }

    /// Prepares a pointer that becomes valid at the same instant as an atomic
    /// namespace swap. Before the swap it cannot authorize the restore temp;
    /// after the swap it names the displaced live inode, including any writes
    /// that arrive through a descriptor held across teardown.
    private static func prepareAtomicSwapDisplacementAuthority(
        transcriptURL: URL,
        externalURL: URL,
        protectedSnapshot: TeardownTranscriptSnapshot,
        expectedLiveStatus: stat,
        candidateId: String,
        fileManager: FileManager
    ) -> DisplacedTranscriptAuthority? {
        let sourceMetadata = recoveryMetadata(
            atSnapshotPath: protectedSnapshot.snapshotPath
        )
        let sessionId: String
        if let metadataSessionId = sourceMetadata?.sessionId,
           isSafeSessionIdPathComponent(metadataSessionId) {
            sessionId = metadataSessionId
        } else {
            sessionId = "displaced-\(UUID().uuidString)"
        }
        let recoveryDirectory = URL(
            fileURLWithPath: protectedSnapshot.snapshotPath
        ).deletingLastPathComponent()
        let pointerURL = recoveryDirectory.appendingPathComponent(
            "\(sessionId)-pointer-\(candidateId).jsonl",
            isDirectory: false
        )
        guard createRecoveryPointerFile(at: pointerURL) else {
            return nil
        }
        guard let pointerInitialVersion = stableRegularFileVersion(
            atPath: pointerURL.path,
            fileManager: fileManager
        ) else {
            _ = durablyRemoveRecoverySnapshot(atPath: pointerURL.path)
            return nil
        }
        var keepPointer = false
        defer {
            if !keepPointer {
                _ = durablyRemoveRecoverySnapshot(
                    atPath: pointerURL.path,
                    expectedSnapshotVersion: pointerInitialVersion
                )
            }
        }
        let liveVersion = stableRegularFileVersion(
            atPath: transcriptURL.path,
            fileManager: fileManager
        )
        let guardedProcesses = sourceMetadata?.guardedProcesses?
            .compactMap(\.processIdentity) ?? protectedSnapshot.guardedProcessIdentities
        let hasUncaptured = sourceMetadata?.hasUncapturedGuardedProcesses
            ?? protectedSnapshot.hasUncapturedGuardedProcesses
        let ownerIdentity = AgentPIDProcessIdentity(pid: getpid())
        let pointerSnapshot = TeardownTranscriptSnapshot(
            transcriptPath: protectedSnapshot.transcriptPath,
            snapshotPath: pointerURL.path,
            liveFileVersion: liveVersion,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured
        )
        let liveSnapshot = TeardownTranscriptSnapshot(
            transcriptPath: protectedSnapshot.transcriptPath,
            snapshotPath: transcriptURL.path,
            liveFileVersion: liveVersion,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured
        )
        let externalDevice = UInt64(expectedLiveStatus.st_dev)
        let externalFile = UInt64(expectedLiveStatus.st_ino)
        let capturedAt = Date()
        guard persistRecoveryMetadata(
            for: pointerSnapshot,
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: liveVersion,
            ownerProcessIdentity: ownerIdentity,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured,
            candidateId: candidateId,
            externalCandidatePath: externalURL.path,
            externalFileDevice: externalDevice,
            externalFileNumber: externalFile
        ), synchronizeRegularFileAndContainingDirectory(atPath: pointerURL.path),
           persistRecoveryMetadata(
            for: liveSnapshot,
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: liveVersion,
            ownerProcessIdentity: ownerIdentity,
            guardedProcessIdentities: guardedProcesses,
            hasUncapturedGuardedProcesses: hasUncaptured,
            candidateId: candidateId,
            externalCandidatePath: externalURL.path,
            externalFileDevice: externalDevice,
            externalFileNumber: externalFile
           ), synchronizeRegularFileAndContainingDirectory(atPath: transcriptURL.path),
           pathStillMatches(
            transcriptURL.path,
            expectedExists: true,
            expectedStatus: expectedLiveStatus
           ), transcriptContainsOnlyNonProtectiveMetadata(
            atPath: transcriptURL.path,
            fileManager: fileManager
           ), let durablePointerVersion = stableRegularFileVersion(
            atPath: pointerURL.path,
            fileManager: fileManager
           ) else {
            return nil
        }
        keepPointer = true
        return DisplacedTranscriptAuthority(
            authorityURL: pointerURL,
            authorityVersion: durablePointerVersion,
            contentURL: externalURL,
            contentIdentity: expectedLiveStatus
        )
    }

    private static func preserveDisplacedLiveTranscript(
        transcriptURL: URL,
        protectedSnapshot: TeardownTranscriptSnapshot,
        expectedLiveStatus: stat,
        fileManager: FileManager
    ) -> DisplacedTranscriptAuthority? {
        let sourceMetadata = recoveryMetadata(
            atSnapshotPath: protectedSnapshot.snapshotPath
        )
        let sessionId: String
        if let metadataSessionId = sourceMetadata?.sessionId,
           isSafeSessionIdPathComponent(metadataSessionId) {
            sessionId = metadataSessionId
        } else {
            sessionId = "displaced-\(UUID().uuidString)"
        }
        let candidateId = UUID().uuidString
        let capturedAt = Date()
        let recoveryDirectory = URL(
            fileURLWithPath: protectedSnapshot.snapshotPath
        ).deletingLastPathComponent()
        let preservedURL = recoveryDirectory.appendingPathComponent(
            "\(sessionId)-displaced-\(candidateId).jsonl",
            isDirectory: false
        )
        let liveSnapshot = TeardownTranscriptSnapshot(
            transcriptPath: protectedSnapshot.transcriptPath,
            snapshotPath: transcriptURL.path
        )
        guard persistRecoveryMetadata(
            for: liveSnapshot,
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: protectedSnapshot.liveFileVersion,
            ownerProcessIdentity: AgentPIDProcessIdentity(pid: getpid()),
            guardedProcessIdentities: protectedSnapshot.guardedProcessIdentities,
            hasUncapturedGuardedProcesses:
                protectedSnapshot.hasUncapturedGuardedProcesses,
            candidateId: candidateId
        ), synchronizeRegularFileAndContainingDirectory(atPath: transcriptURL.path),
           pathStillMatches(
            transcriptURL.path,
            expectedExists: true,
            expectedStatus: expectedLiveStatus
           ), transcriptContainsOnlyNonProtectiveMetadata(
            atPath: transcriptURL.path,
            fileManager: fileManager
           ) else {
            return nil
        }
        if atomicallyRename(transcriptURL, to: preservedURL) {
            guard synchronizeContainingDirectory(atPath: transcriptURL.path),
                  synchronizeRegularFileAndContainingDirectory(atPath: preservedURL.path) else {
                if atomicallyRename(preservedURL, to: transcriptURL) {
                    _ = synchronizeRegularFileAndContainingDirectory(
                        atPath: transcriptURL.path
                    )
                }
                return nil
            }
            guard let authorityVersion = stableRegularFileVersion(
                atPath: preservedURL.path,
                fileManager: fileManager
            ) else { return nil }
            var contentIdentity = stat()
            guard lstat(preservedURL.path, &contentIdentity) == 0 else { return nil }
            return DisplacedTranscriptAuthority(
                authorityURL: preservedURL,
                authorityVersion: authorityVersion,
                contentURL: preservedURL,
                contentIdentity: contentIdentity
            )
        }
        guard errno == EXDEV else { return nil }
        return preserveDisplacedLiveTranscriptAcrossVolumes(
            transcriptURL: transcriptURL,
            recoveryDirectory: recoveryDirectory,
            protectedSnapshot: protectedSnapshot,
            expectedLiveStatus: expectedLiveStatus,
            sessionId: sessionId,
            candidateId: candidateId,
            capturedAt: capturedAt,
            fileManager: fileManager
        )
    }

    static func preserveDisplacedLiveTranscriptAcrossVolumes(
        transcriptURL: URL,
        recoveryDirectory: URL,
        protectedSnapshot: TeardownTranscriptSnapshot,
        expectedLiveStatus: stat,
        sessionId: String,
        candidateId: String,
        capturedAt: Date,
        fileManager: FileManager
    ) -> DisplacedTranscriptAuthority? {
        let externalURL = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(transcriptURL.lastPathComponent).cmux-recovery-\(candidateId).jsonl",
                isDirectory: false
            )
        let pointerURL = recoveryDirectory.appendingPathComponent(
            "\(sessionId)-pointer-\(candidateId).jsonl",
            isDirectory: false
        )
        guard createRecoveryPointerFile(at: pointerURL) else { return nil }
        guard let pointerInitialVersion = stableRegularFileVersion(
            atPath: pointerURL.path,
            fileManager: fileManager
        ) else {
            _ = durablyRemoveRecoverySnapshot(atPath: pointerURL.path)
            return nil
        }
        var keepPointer = false
        defer {
            if !keepPointer {
                _ = durablyRemoveRecoverySnapshot(
                    atPath: pointerURL.path,
                    expectedSnapshotVersion: pointerInitialVersion
                )
            }
        }
        let externalDevice = UInt64(expectedLiveStatus.st_dev)
        let externalFile = UInt64(expectedLiveStatus.st_ino)
        let liveVersion = stableRegularFileVersion(
            atPath: transcriptURL.path,
            fileManager: fileManager
        )
        let ownerIdentity = AgentPIDProcessIdentity(pid: getpid())
        let pointerSnapshot = TeardownTranscriptSnapshot(
            transcriptPath: protectedSnapshot.transcriptPath,
            snapshotPath: pointerURL.path,
            liveFileVersion: liveVersion,
            guardedProcessIdentities: protectedSnapshot.guardedProcessIdentities,
            hasUncapturedGuardedProcesses:
                protectedSnapshot.hasUncapturedGuardedProcesses
        )
        let liveSnapshot = TeardownTranscriptSnapshot(
            transcriptPath: protectedSnapshot.transcriptPath,
            snapshotPath: transcriptURL.path,
            liveFileVersion: liveVersion,
            guardedProcessIdentities: protectedSnapshot.guardedProcessIdentities,
            hasUncapturedGuardedProcesses:
                protectedSnapshot.hasUncapturedGuardedProcesses
        )
        guard persistRecoveryMetadata(
            for: pointerSnapshot,
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: liveVersion,
            ownerProcessIdentity: ownerIdentity,
            guardedProcessIdentities: protectedSnapshot.guardedProcessIdentities,
            hasUncapturedGuardedProcesses:
                protectedSnapshot.hasUncapturedGuardedProcesses,
            candidateId: candidateId,
            externalCandidatePath: externalURL.path,
            externalFileDevice: externalDevice,
            externalFileNumber: externalFile
        ), synchronizeRegularFileAndContainingDirectory(atPath: pointerURL.path),
           persistRecoveryMetadata(
            for: liveSnapshot,
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: liveVersion,
            ownerProcessIdentity: ownerIdentity,
            guardedProcessIdentities: protectedSnapshot.guardedProcessIdentities,
            hasUncapturedGuardedProcesses:
                protectedSnapshot.hasUncapturedGuardedProcesses,
            candidateId: candidateId,
            externalCandidatePath: externalURL.path,
            externalFileDevice: externalDevice,
            externalFileNumber: externalFile
           ), synchronizeRegularFileAndContainingDirectory(atPath: transcriptURL.path),
           pathStillMatches(
            transcriptURL.path,
            expectedExists: true,
            expectedStatus: expectedLiveStatus
           ), transcriptContainsOnlyNonProtectiveMetadata(
            atPath: transcriptURL.path,
            fileManager: fileManager
           ) else {
            return nil
        }
        guard atomicallyRename(transcriptURL, to: externalURL) else { return nil }
        keepPointer = true
        guard synchronizeContainingDirectory(atPath: transcriptURL.path),
              synchronizeRegularFileAndContainingDirectory(atPath: externalURL.path),
              let authorityVersion = stableRegularFileVersion(
                atPath: pointerURL.path,
                fileManager: fileManager
              ) else {
            if atomicallyRename(externalURL, to: transcriptURL),
               synchronizeRegularFileAndContainingDirectory(atPath: transcriptURL.path) {
                keepPointer = false
            }
            return nil
        }
        var contentIdentity = stat()
        guard lstat(externalURL.path, &contentIdentity) == 0,
              UInt64(contentIdentity.st_dev) == externalDevice,
              UInt64(contentIdentity.st_ino) == externalFile else {
            return nil
        }
        return DisplacedTranscriptAuthority(
            authorityURL: pointerURL,
            authorityVersion: authorityVersion,
            contentURL: externalURL,
            contentIdentity: contentIdentity
        )
    }

    private static func createRecoveryPointerFile(at url: URL) -> Bool {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        let bytes = Data("{\"type\":\"mode\",\"mode\":\"recovery-pointer\"}\n".utf8)
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count,
              fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              fsync(descriptor) == 0 else {
            _ = Darwin.unlink(url.path)
            return false
        }
        return synchronizeContainingDirectory(atPath: url.path)
    }

    @discardableResult
    private static func rollBackDisplacedTranscript(
        _ authority: DisplacedTranscriptAuthority,
        to transcriptURL: URL,
        fileManager: FileManager
    ) -> Bool {
        var contentStatus = stat()
        guard lstat(authority.contentURL.path, &contentStatus) == 0,
              sameRegularFileIdentity(contentStatus, authority.contentIdentity),
              atomicallyRename(authority.contentURL, to: transcriptURL),
              synchronizeRegularFileAndContainingDirectory(
                atPath: transcriptURL.path
              ) else {
            return false
        }
        if authority.authorityURL.path != authority.contentURL.path {
            _ = durablyRemoveRecoverySnapshot(
                atPath: authority.authorityURL.path,
                afterSynchronizingLivePath: transcriptURL.path,
                expectedSnapshotVersion: authority.authorityVersion
            )
        }
        return true
    }

    private static func pathStillMatches(
        _ path: String,
        expectedExists: Bool,
        expectedStatus: stat
    ) -> Bool {
        var status = stat()
        if lstat(path, &status) != 0 {
            return !expectedExists && errno == ENOENT
        }
        return expectedExists
            && stableFileStatus(status, matches: expectedStatus)
            && status.st_uid == geteuid()
            && status.st_nlink == 1
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
                liveFileVersion: snapshot.liveFileVersion,
                guardedProcessIdentities: snapshot.guardedProcessIdentities,
                hasUncapturedGuardedProcesses: snapshot.hasUncapturedGuardedProcesses
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
                ownerRuntimeMetadata: .init(
                    runtimeId: sourceMetadata.ownerRuntimeId,
                    bundleIdentifier: sourceMetadata.ownerBundleIdentifier
                ),
                guardedProcessIdentities: sourceMetadata.guardedProcesses?.compactMap(\.processIdentity) ?? [],
                hasUncapturedGuardedProcesses:
                    sourceMetadata.hasUncapturedGuardedProcesses == true,
                candidateId: sourceMetadata.candidateId,
                externalCandidatePath: sourceMetadata.externalCandidatePath,
                externalFileDevice: sourceMetadata.externalFileDevice,
                externalFileNumber: sourceMetadata.externalFileNumber
            )
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: retainedURL.path)
            return
        }

        var displacedRetainedVersion: TeardownTranscriptFileVersion?
        var retainedMetadata: RecoveryMetadata?
        var retainedExists = fileManager.fileExists(atPath: retainedURL.path)
        if retainedExists {
            retainedMetadata = validatedDurableRetainedMetadata(
                at: retainedURL,
                fileManager: fileManager
            )
            if retainedMetadata == nil {
                moveInvalidRecoveryEntriesAside(
                    [retainedURL],
                    in: retainedURL.deletingLastPathComponent(),
                    fileManager: fileManager,
                    cancellationCheck: { false }
                )
                retainedExists = fileManager.fileExists(atPath: retainedURL.path)
            }
        }
        if retainedExists {
            guard let retainedMetadata,
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
                if let snapshotVersion = stableRegularFileVersion(
                    atPath: snapshotURL.path,
                    fileManager: fileManager
                ) {
                    _ = durablyRemoveRecoverySnapshot(
                        atPath: snapshotURL.path,
                        afterSynchronizingLivePath: retainedURL.path,
                        expectedSnapshotVersion: snapshotVersion
                    )
                }
                return
            }
            guard capturedAt >= (retainedMetadata.capturedAt ?? .distantPast),
                  let sourceVersion = stableRegularFileVersion(
                    atPath: snapshotURL.path,
                    fileManager: fileManager
                  ),
                  let retainedVersion = stableRegularFileVersion(
                    atPath: retainedURL.path,
                    fileManager: fileManager
                  ),
                  file(
                    atPath: snapshotURL.path,
                    stablyContainsPrefixAtPath: retainedURL.path,
                    fileManager: fileManager
                  ),
                  stableRegularFileVersion(
                    atPath: snapshotURL.path,
                    fileManager: fileManager
                  ) == sourceVersion,
                  stableRegularFileVersion(
                    atPath: retainedURL.path,
                    fileManager: fileManager
                  ) == retainedVersion else {
                // Later timestamps alone do not prove append-only ancestry.
                // Preserve divergent branches as separate UUID snapshots.
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
                return
            }
            // Preserve both recovery generations through the replacement.
            // The swap is accepted only when both exact inodes and their
            // append-only ancestry still match after the namespace commit.
            guard renamex_np(
                snapshotURL.path,
                retainedURL.path,
                UInt32(RENAME_SWAP)
            ) == 0 else {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
                return
            }
            let swapIsExact = stableRegularFileVersion(
                atPath: retainedURL.path,
                fileManager: fileManager
            ) == sourceVersion
                && stableRegularFileVersion(
                    atPath: snapshotURL.path,
                    fileManager: fileManager
                ) == retainedVersion
                && file(
                    atPath: retainedURL.path,
                    stablyContainsPrefixAtPath: snapshotURL.path,
                    fileManager: fileManager
                )
            guard swapIsExact else {
                if stableRegularFileVersion(
                    atPath: retainedURL.path,
                    fileManager: fileManager
                ) == sourceVersion,
                   stableRegularFileVersion(
                    atPath: snapshotURL.path,
                    fileManager: fileManager
                   ) == retainedVersion {
                    _ = renamex_np(
                        snapshotURL.path,
                        retainedURL.path,
                        UInt32(RENAME_SWAP)
                    )
                }
                return
            }
            displacedRetainedVersion = retainedVersion
        } else {
            guard let sourceVersion = stableRegularFileVersion(
                atPath: snapshotURL.path,
                fileManager: fileManager
            ) else {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
                return
            }
            guard atomicallyRename(snapshotURL, to: retainedURL),
                  stableRegularFileVersion(
                    atPath: retainedURL.path,
                    fileManager: fileManager
                  ) == sourceVersion else {
                try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: snapshotURL.path)
                return
            }
        }
        let metadataPersisted = persistRecoveryMetadata(
            for: TeardownTranscriptSnapshot(
                transcriptPath: snapshot.transcriptPath,
                snapshotPath: retainedURL.path
            ),
            sessionId: sessionId,
            capturedAt: capturedAt,
            liveFileVersion: sourceMetadata.liveFileVersion,
            ownerProcessIdentity: sourceMetadata.ownerProcessIdentity,
            ownerRuntimeMetadata: .init(
                runtimeId: sourceMetadata.ownerRuntimeId,
                bundleIdentifier: sourceMetadata.ownerBundleIdentifier
            ),
            guardedProcessIdentities: sourceMetadata.guardedProcesses?.compactMap(\.processIdentity) ?? [],
            hasUncapturedGuardedProcesses:
                sourceMetadata.hasUncapturedGuardedProcesses == true,
            candidateId: sourceMetadata.candidateId,
            externalCandidatePath: sourceMetadata.externalCandidatePath,
            externalFileDevice: sourceMetadata.externalFileDevice,
            externalFileNumber: sourceMetadata.externalFileNumber
        )
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: retainedURL.path)
        guard metadataPersisted,
              synchronizeRegularFileAndContainingDirectory(atPath: retainedURL.path) else {
            // Both inodes remain metadata-bearing recovery candidates. Do not
            // retire the displaced generation without durable new authority.
            return
        }
        if let displacedRetainedVersion {
            _ = durablyRemoveRecoverySnapshot(
                atPath: snapshotURL.path,
                afterSynchronizingLivePath: retainedURL.path,
                expectedSnapshotVersion: displacedRetainedVersion
            )
        }
    }

    /// Reconciles snapshots whose in-memory post-teardown monitor disappeared
    /// with the prior app process. Metadata is stored on the snapshot inode, so
    /// the retained-slot rename cannot separate the protected bytes from their
    /// destination path.
    @discardableResult
    static func recoverPendingSnapshots(
        snapshotDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumProcessIdentityProbes: Int = Self.maxStartupRecoveryProcessIdentityProbes,
        cancellationCheck: @Sendable () -> Bool = { false }
    ) -> Int {
        guard !cancellationCheck() else { return 0 }
        guard let directory = snapshotDirectory ?? defaultSnapshotDirectoryURL() else {
            return 0
        }
        guard ensurePrivateRecoveryDirectory(
            at: directory,
            createIfMissing: false,
            fileManager: fileManager
        ) else { return 0 }
        guard let lockDescriptor = acquireRecoveryDirectoryLock(in: directory) else {
            return 0
        }
        defer { releaseRecoveryDirectoryLock(lockDescriptor) }
        guard let directoryStream = recoveryDirectoryStream(in: directory) else { return 0 }
        defer { closedir(directoryStream) }
        let cursor = recoveryCursor(lockDescriptor: lockDescriptor)
        var processProbeBudget = RecoveryProcessProbeBudget(
            remaining: max(0, maximumProcessIdentityProbes)
        )
        let scan = validatedRecoveryCandidates(
            in: directory,
            directoryStream: directoryStream,
            maximumEntries: maxStartupRecoveryDirectoryEntries,
            afterTranscriptPath: cursor.transcriptPath,
            fileManager: fileManager,
            processProbeBudget: &processProbeBudget,
            cancellationCheck: cancellationCheck
        )
        let restored = recoverPendingCandidates(
            scan.candidates,
            lockDescriptor: lockDescriptor,
            maximumCandidates: maxStartupRecoverySnapshots,
            fileManager: fileManager,
            cancellationCheck: cancellationCheck
        ).restoredCount
        moveInvalidRecoveryEntriesAside(
            scan.invalidEntries,
            in: directory,
            fileManager: fileManager,
            cancellationCheck: cancellationCheck
        )
        return restored
    }

    static func recoverPendingSnapshotsAwaitingLock(
        snapshotDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumProcessIdentityProbes: Int = Self.maxStartupRecoveryProcessIdentityProbes,
        cancellationCheck: @escaping @Sendable () -> Bool = { false }
    ) async -> Int {
        guard !cancellationCheck(),
              let directory = snapshotDirectory ?? defaultSnapshotDirectoryURL() else {
            return 0
        }
        guard ensurePrivateRecoveryDirectory(
            at: directory,
            createIfMissing: false,
            fileManager: fileManager
        ) else { return 0 }
        // A dedicated serial Dispatch queue owns the only blocking flock wait;
        // it never occupies the main actor or Swift's cooperative executor.
        // Cancellation cannot interrupt flock, so a cancelled generation
        // releases immediately after acquisition and its successor then runs.
        let lockDescriptor = await acquireRecoveryDirectoryLockAwaitingContention(
            in: directory
        )
        guard let lockDescriptor else { return 0 }
        defer { releaseRecoveryDirectoryLock(lockDescriptor) }
        guard !cancellationCheck() else { return 0 }
        guard let directoryStream = recoveryDirectoryStream(in: directory) else { return 0 }
        defer { closedir(directoryStream) }
        let cursor = recoveryCursor(lockDescriptor: lockDescriptor)

        // DIR cookies are valid only for this open stream. Scan fixed-size
        // batches and yield between them; never persist seek offsets across a
        // reopened or mutated directory.
        var accumulatedCandidates: [PendingRecoverySnapshot] = []
        var accumulatedMetadataBytes = 0
        var accumulatedContentBytes: UInt64 = 0
        var budgetBlockedTranscriptPaths: Set<String> = []
        var invalidEntries: [URL] = []
        var processProbeBudget = RecoveryProcessProbeBudget(
            remaining: max(0, maximumProcessIdentityProbes)
        )
        while !cancellationCheck() {
            let scan = validatedRecoveryCandidates(
                in: directory,
                directoryStream: directoryStream,
                maximumEntries: maxStartupRecoveryDirectoryEntries,
                afterTranscriptPath: cursor.transcriptPath,
                fileManager: fileManager,
                processProbeBudget: &processProbeBudget,
                cancellationCheck: cancellationCheck
            )
            budgetBlockedTranscriptPaths.formUnion(scan.budgetBlockedTranscriptPaths)
            accumulatedCandidates.removeAll { candidate in
                budgetBlockedTranscriptPaths.contains(
                    (candidate.metadata.transcriptPath as NSString).standardizingPath
                )
            }
            accumulatedMetadataBytes = accumulatedCandidates.reduce(0) {
                $0 + $1.metadataByteCount
            }
            accumulatedContentBytes = accumulatedCandidates.reduce(0) {
                $0 + $1.contentByteCount
            }
            for candidate in scan.candidates {
                insertRecoveryCandidate(
                    candidate,
                    into: &accumulatedCandidates,
                    metadataBytes: &accumulatedMetadataBytes,
                    contentBytes: &accumulatedContentBytes,
                    budgetBlockedTranscriptPaths: &budgetBlockedTranscriptPaths,
                    afterTranscriptPath: cursor.transcriptPath
                )
            }
            if invalidEntries.count < maxStartupRecoveryInvalidMovesPerLaunch {
                invalidEntries.append(contentsOf: scan.invalidEntries.prefix(
                    maxStartupRecoveryInvalidMovesPerLaunch - invalidEntries.count
                ))
            }
            if scan.reachedEnd || scan.examinedEntries == 0 { break }
            await Task.yield()
        }
        let restoredCount = recoverPendingCandidates(
            accumulatedCandidates,
            lockDescriptor: lockDescriptor,
            maximumCandidates: maxStartupRecoverySnapshots,
            fileManager: fileManager,
            cancellationCheck: cancellationCheck
        ).restoredCount
        moveInvalidRecoveryEntriesAside(
            invalidEntries,
            in: directory,
            fileManager: fileManager,
            cancellationCheck: cancellationCheck
        )
        return restoredCount
    }

    private static func recoveryDirectoryStream(
        in directory: URL
    ) -> UnsafeMutablePointer<DIR>? {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }
        var status = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              lstat(directory.path, &pathStatus) == 0,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_uid == geteuid(),
              pathStatus.st_dev == status.st_dev,
              pathStatus.st_ino == status.st_ino else {
            Darwin.close(descriptor)
            return nil
        }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            return nil
        }
        return stream
    }

    private static func recoverPendingCandidates(
        _ candidates: [PendingRecoverySnapshot],
        lockDescriptor: Int32,
        maximumCandidates: Int,
        fileManager: FileManager,
        cancellationCheck: @Sendable () -> Bool
    ) -> (restoredCount: Int, processedCount: Int) {
        let cursor = recoveryCursor(lockDescriptor: lockDescriptor)
        var candidatesByTranscript: [String: [PendingRecoverySnapshot]] = [:]
        for candidate in candidates {
            guard !cancellationCheck() else { break }
            let transcriptKey = (candidate.metadata.transcriptPath as NSString).standardizingPath
            candidatesByTranscript[transcriptKey, default: []].append(candidate)
        }
        guard !cancellationCheck(), maximumCandidates > 0 else { return (0, 0) }
        guard !candidatesByTranscript.isEmpty else { return (0, 0) }

        for key in Array(candidatesByTranscript.keys) {
            guard let values = candidatesByTranscript[key],
                  let ordered = recoveryCandidatesWithUniversalAppendSuperset(values) else {
                candidatesByTranscript.removeValue(forKey: key)
                continue
            }
            candidatesByTranscript[key] = ordered
        }
        let orderedTranscriptKeys = rotatedRecoveryTranscriptKeys(
            Array(candidatesByTranscript.keys).sorted(),
            after: cursor.transcriptPath
        )
        var nextIndexByTranscript: [String: Int] = [:]
        var selectedByTranscript: [String: [PendingRecoverySnapshot]] = [:]
        var selectedCount = 0
        var lastSelectedTranscript: String?
        while selectedCount < maximumCandidates, !cancellationCheck() {
            var appendedInPass = false
            for transcriptKey in orderedTranscriptKeys where selectedCount < maximumCandidates {
                guard !cancellationCheck() else { break }
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
            persistRecoveryCursor(
                RecoveryCursorState(transcriptPath: lastSelectedTranscript),
                lockDescriptor: lockDescriptor
            )
        }

        var restoredCount = 0
        for transcriptKey in orderedTranscriptKeys {
            guard !cancellationCheck() else { break }
            guard let newestFirst = selectedByTranscript[transcriptKey] else { continue }
            var newestValidSnapshotWasCommitted = false
            for originalCandidate in newestFirst {
                guard !cancellationCheck() else { break }
                guard let candidate = claimRecoveryCandidate(
                    originalCandidate,
                    fileManager: fileManager
                ) else {
                    // A newer candidate that cannot be claimed is still
                    // unresolved authority. Never commit an older generation
                    // ahead of it.
                    break
                }
                let snapshot = TeardownTranscriptSnapshot(
                    transcriptPath: candidate.metadata.transcriptPath,
                    snapshotPath: candidate.contentURL.path,
                    liveFileVersion: candidate.metadata.liveFileVersion,
                    guardedProcessIdentities: candidate.metadata.guardedProcesses?
                        .compactMap(\.processIdentity) ?? [],
                    hasUncapturedGuardedProcesses:
                        candidate.metadata.hasUncapturedGuardedProcesses == true
                )
                guard let claimedAuthorityVersion = stableRegularFileVersion(
                    atPath: candidate.url.path,
                    fileManager: fileManager
                ),
                      let claimedSnapshotVersion = stableRegularFileVersion(
                    atPath: snapshot.snapshotPath,
                    fileManager: fileManager
                ) else {
                    preserveClaimedRecoveryCandidate(
                        candidate,
                        at: originalCandidate.url,
                        fileManager: fileManager
                    )
                    break
                }
                guard transcriptHasConversationTurns(
                    atPath: snapshot.snapshotPath,
                    fileManager: fileManager
                ) else {
                    if transcriptContainsOnlyNonProtectiveMetadata(
                        atPath: snapshot.snapshotPath,
                        fileManager: fileManager
                    ) {
                        if durablyRemoveClaimedRecoveryCandidate(
                            candidate,
                            authorityVersion: claimedAuthorityVersion,
                            contentVersion: claimedSnapshotVersion,
                            afterSynchronizingLivePath: nil
                        ) {
                            continue
                        } else {
                            preserveClaimedRecoveryCandidate(
                                candidate,
                                at: originalCandidate.url,
                                fileManager: fileManager
                            )
                        }
                    } else {
                        preserveClaimedRecoveryCandidate(
                            candidate,
                            at: originalCandidate.url,
                            fileManager: fileManager
                        )
                    }
                    break
                }
                if newestValidSnapshotWasCommitted {
                    if file(
                        atPath: snapshot.transcriptPath,
                        stablyContainsPrefixAtPath: snapshot.snapshotPath,
                        fileManager: fileManager
                    ) {
                        _ = durablyRemoveClaimedRecoveryCandidate(
                            candidate,
                            authorityVersion: claimedAuthorityVersion,
                            contentVersion: claimedSnapshotVersion,
                            afterSynchronizingLivePath: snapshot.transcriptPath
                        )
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
                    _ = durablyRemoveClaimedRecoveryCandidate(
                        candidate,
                        authorityVersion: claimedAuthorityVersion,
                        contentVersion: claimedSnapshotVersion,
                        afterSynchronizingLivePath: snapshot.transcriptPath
                    )
                    newestValidSnapshotWasCommitted = true
                    continue
                }
                if restoreIfClobberedWhileHoldingDirectoryLock(snapshot, fileManager: fileManager) {
                    restoredCount += 1
                    _ = durablyRemoveClaimedRecoveryCandidate(
                        candidate,
                        authorityVersion: claimedAuthorityVersion,
                        contentVersion: claimedSnapshotVersion,
                        afterSynchronizingLivePath: snapshot.transcriptPath
                    )
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
        return (restoredCount, selectedCount)
    }

    /// Wall clocks are not generation authority. A clock rollback can make a
    /// later append snapshot look older, so restore only a candidate whose
    /// stable bytes contain every other admitted generation for the transcript.
    /// Equal-size contenders must be byte-equivalent or no generation wins.
    private static func recoveryCandidatesWithUniversalAppendSuperset(
        _ candidates: [PendingRecoverySnapshot],
        fileManager: FileManager = .default
    ) -> [PendingRecoverySnapshot]? {
        guard let maximumContentBytes = candidates.map(\.contentByteCount).max() else {
            return nil
        }
        let contenders = candidates
            .filter { $0.contentByteCount == maximumContentBytes }
            .sorted(by: recoveryCandidateIsNewer)
        guard let universal = contenders.first else { return nil }

        for candidate in candidates {
            if candidate.contentURL.path == universal.contentURL.path {
                guard candidate.contentVersion == universal.contentVersion else { return nil }
                continue
            }
            guard file(
                atPath: universal.contentURL.path,
                stablyContainsPrefixAtPath: candidate.contentURL.path,
                fileManager: fileManager
            ) else {
                return nil
            }
        }
        for candidate in candidates {
            guard stableRegularFileVersion(
                    atPath: candidate.url.path,
                    fileManager: fileManager
                  ) == candidate.authorityVersion,
                  stableRegularFileVersion(
                    atPath: candidate.contentURL.path,
                    fileManager: fileManager
                  ) == candidate.contentVersion else {
                return nil
            }
        }

        return [universal] + candidates
            .filter { $0.url.path != universal.url.path }
            .sorted(by: recoveryCandidateIsNewer)
    }

    static func transcriptCandidates(projectRoot: String, sessionId: String) -> [String] {
        let directPath = (projectRoot as NSString).appendingPathComponent("\(sessionId).jsonl")
        let nestedPath = (((projectRoot as NSString).appendingPathComponent(sessionId) as NSString).appendingPathComponent("messages") as NSString).appendingPathComponent("\(sessionId).jsonl")
        return [directPath, nestedPath]
    }

    private static func isSafeSessionIdPathComponent(_ sessionId: String) -> Bool {
        !sessionId.isEmpty
            && sessionId != "."
            && sessionId != ".."
            && !sessionId.contains("/")
            && !sessionId.contains("\\")
            && !sessionId.unicodeScalars.contains {
                $0.properties.generalCategory == .control
            }
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
        for accountPath in boundedOwnedChildDirectories(atPath: accountRoot) {
            appendRoot(accountPath)
        }
        appendRoot((homeDirectory as NSString).appendingPathComponent(".claude"))
        appendRoot(ClaudeConfigDirectoryPath.preferredPath(
            (homeDirectory as NSString).appendingPathComponent(".subrouter/codex/claude"),
            fileManager: fileManager,
            homeDirectory: homeDirectory)
        )
        return roots
    }

    private static func boundedOwnedChildDirectories(
        atPath rootPath: String,
        maximumEntries: Int = 256,
        maximumDirectories: Int = 64
    ) -> [String] {
        let descriptor = open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0, let stream = fdopendir(descriptor) else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return []
        }
        defer { closedir(stream) }
        var examinedEntries = 0
        var directories: [String] = []
        while examinedEntries < max(0, maximumEntries),
              directories.count < max(0, maximumDirectories),
              let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            examinedEntries += 1
            guard !name.isEmpty, !name.contains("/") else { continue }
            var status = stat()
            guard fstatat(
                dirfd(stream),
                name,
                &status,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid() else {
                continue
            }
            directories.append((rootPath as NSString).appendingPathComponent(name))
        }
        return directories.sorted()
    }

    private static func capturedGuardedProcessIdentities(
        from processIDs: Set<Int>,
        maximumIdentities: Int
    ) -> (identities: [AgentPIDProcessIdentity], hasUncaptured: Bool) {
        let validProcessIDs = processIDs.filter {
            $0 > 0 && $0 <= Int(Int32.max)
        }
        let rootProcessIDs = validProcessIDs.filter { processID in
            guard let parentProcessID = parentProcessID(of: processID) else {
                return true
            }
            return !validProcessIDs.contains(parentProcessID)
        }.sorted()
        let rootSet = Set(rootProcessIDs)
        let orderedProcessIDs = rootProcessIDs
            + validProcessIDs.filter { !rootSet.contains($0) }.sorted()
        var identities: [AgentPIDProcessIdentity] = []
        var hasUncaptured = false
        for processID in orderedProcessIDs {
            guard identities.count < maximumIdentities else {
                if processIsAlive(pid_t(processID)) { hasUncaptured = true }
                continue
            }
            if let identity = AgentPIDProcessIdentity(pid: pid_t(processID)) {
                identities.append(identity)
            } else if processIsAlive(pid_t(processID)) {
                hasUncaptured = true
            }
        }
        return (identities, hasUncaptured)
    }

    private static func parentProcessID(of processID: Int) -> Int? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let size = proc_pidinfo(
            pid_t(processID),
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(expectedSize)
        )
        guard size == expectedSize else { return nil }
        return Int(info.pbi_ppid)
    }

    private static func processIsAlive(_ processID: pid_t) -> Bool {
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func persistRecoveryMetadata(
        for snapshot: TeardownTranscriptSnapshot,
        sessionId: String,
        capturedAt: Date,
        liveFileVersion: TeardownTranscriptFileVersion? = nil,
        ownerProcessIdentity: AgentPIDProcessIdentity? = AgentPIDProcessIdentity(pid: getpid()),
        ownerRuntimeMetadata: RecoveryOwnerRuntimeMetadata? = nil,
        guardedProcessIdentities: [AgentPIDProcessIdentity] = [],
        hasUncapturedGuardedProcesses: Bool = false,
        candidateId: String? = nil,
        candidateState: String = "recoverable",
        externalCandidatePath: String? = nil,
        externalFileDevice: UInt64? = nil,
        externalFileNumber: UInt64? = nil,
        destinationDescriptor: Int32? = nil
    ) -> Bool {
        let ownerRuntimeId: String?
        let ownerBundleIdentifier: String?
        if let ownerRuntimeMetadata {
            ownerRuntimeId = ownerRuntimeMetadata.runtimeId
            ownerBundleIdentifier = ownerRuntimeMetadata.bundleIdentifier
        } else {
            ownerRuntimeId = ownerProcessIdentity.flatMap { _ in
                normalized(ProcessInfo.processInfo.environment["CMUX_RUNTIME_ID"])
            }
            ownerBundleIdentifier = ownerProcessIdentity == nil
                ? nil
                : Bundle.main.bundleIdentifier
        }
        let resolvedCandidateId = candidateId
            ?? recoveryMetadata(atSnapshotPath: snapshot.snapshotPath)?.candidateId
            ?? UUID().uuidString
        guard isSafeSessionIdPathComponent(sessionId),
              UUID(uuidString: resolvedCandidateId) != nil,
              let data = try? JSONEncoder().encode(RecoveryMetadata(
                version: 2,
                sessionId: sessionId,
                transcriptPath: snapshot.transcriptPath,
                snapshotPath: nil,
                candidateId: resolvedCandidateId,
                candidateState: candidateState,
                externalCandidatePath: externalCandidatePath,
                externalFileDevice: externalFileDevice,
                externalFileNumber: externalFileNumber,
                capturedAt: capturedAt,
                liveFileNumber: liveFileVersion?.fileNumber,
                liveFileSize: liveFileVersion?.size,
                liveFileModificationDate: liveFileVersion?.modificationDate,
                ownerProcessId: ownerProcessIdentity?.pid,
                ownerProcessStartSeconds: ownerProcessIdentity?.startSeconds,
                ownerProcessStartMicroseconds: ownerProcessIdentity?.startMicroseconds,
                ownerRuntimeId: ownerRuntimeId,
                ownerBundleIdentifier: ownerBundleIdentifier,
                guardedProcesses: Array(guardedProcessIdentities.prefix(64)).map(RecoveryProcessIdentity.init),
                hasUncapturedGuardedProcesses: hasUncapturedGuardedProcesses
              )),
              !data.isEmpty,
              data.count <= maxRecoveryMetadataBytes else {
            return false
        }
        if let destinationDescriptor {
            return writeRecoveryMetadataData(
                data,
                toDescriptor: destinationDescriptor,
                expectedPath: snapshot.snapshotPath
            )
        }
        return writeRecoveryMetadataData(data, atPath: snapshot.snapshotPath)
    }

    /// Removes only this process generation's ownership after its in-memory
    /// monitor is exhausted. Every byte-authority field remains unchanged, so
    /// startup recovery can claim the candidate without waiting for an app
    /// restart, while a replacement owner can never be retired accidentally.
    static func retireCurrentRecoveryOwner(
        for snapshot: TeardownTranscriptSnapshot,
        expectedSnapshotVersion: TeardownTranscriptFileVersion,
        fileManager: FileManager = .default
    ) -> Bool {
        let snapshotURL = URL(fileURLWithPath: snapshot.snapshotPath)
        guard let lockDescriptor = acquireRecoveryDirectoryLockSynchronously(
            in: snapshotURL.deletingLastPathComponent()
        ) else {
            return false
        }
        defer { releaseRecoveryDirectoryLock(lockDescriptor) }
        guard stableRegularFileVersion(
                atPath: snapshot.snapshotPath,
                fileManager: fileManager
              ) == expectedSnapshotVersion,
              let metadata = recoveryMetadata(
                atSnapshotPath: snapshot.snapshotPath
              ),
              metadata.version == 2,
              recoveryMetadata(metadata, isValidAt: snapshotURL),
              metadata.hasUncapturedGuardedProcesses != true,
              metadata.guardedProcesses?.contains(where: { guarded in
                guard let identity = guarded.processIdentity else { return true }
                return AgentPIDProcessIdentity(pid: identity.pid) == identity
              }) != true else {
            return false
        }

        var recognizedCurrentOwner = false
        if metadata.ownerProcessId != nil
            || metadata.ownerProcessStartSeconds != nil
            || metadata.ownerProcessStartMicroseconds != nil {
            guard let expectedOwner = metadata.ownerProcessIdentity,
                  let currentOwner = AgentPIDProcessIdentity(pid: expectedOwner.pid),
                  currentOwner == expectedOwner,
                  expectedOwner.pid == getpid() else {
                return false
            }
            recognizedCurrentOwner = true
        }
        if let ownerRuntimeId = metadata.ownerRuntimeId {
            guard ownerRuntimeId == normalized(
                ProcessInfo.processInfo.environment["CMUX_RUNTIME_ID"]
            ) else {
                return false
            }
            recognizedCurrentOwner = true
        }
        if let ownerBundleIdentifier = metadata.ownerBundleIdentifier {
            guard ownerBundleIdentifier == Bundle.main.bundleIdentifier else {
                return false
            }
            recognizedCurrentOwner = true
        }
        guard recognizedCurrentOwner else { return false }

        let retiredMetadata = RecoveryMetadata(
            version: metadata.version,
            sessionId: metadata.sessionId,
            transcriptPath: metadata.transcriptPath,
            snapshotPath: metadata.snapshotPath,
            candidateId: metadata.candidateId,
            candidateState: metadata.candidateState,
            externalCandidatePath: metadata.externalCandidatePath,
            externalFileDevice: metadata.externalFileDevice,
            externalFileNumber: metadata.externalFileNumber,
            capturedAt: metadata.capturedAt,
            liveFileNumber: metadata.liveFileNumber,
            liveFileSize: metadata.liveFileSize,
            liveFileModificationDate: metadata.liveFileModificationDate,
            ownerProcessId: nil,
            ownerProcessStartSeconds: nil,
            ownerProcessStartMicroseconds: nil,
            ownerRuntimeId: nil,
            ownerBundleIdentifier: nil,
            guardedProcesses: metadata.guardedProcesses,
            hasUncapturedGuardedProcesses:
                metadata.hasUncapturedGuardedProcesses
        )
        guard let data = try? JSONEncoder().encode(retiredMetadata),
              !data.isEmpty,
              data.count <= maxRecoveryMetadataBytes,
              writeRecoveryMetadataData(
                data,
                atPath: snapshot.snapshotPath
              ),
              synchronizeRegularFileAndContainingDirectory(
                atPath: snapshot.snapshotPath
              ),
              recoveryMetadata(atSnapshotPath: snapshot.snapshotPath)
                == retiredMetadata else {
            return false
        }
        return true
    }

    private static func recoveryMetadata(atSnapshotPath snapshotPath: String) -> RecoveryMetadata? {
        recoveryMetadataEnvelope(atSnapshotPath: snapshotPath)?.metadata
    }

    private static func recoveryMetadataEnvelope(
        atSnapshotPath snapshotPath: String
    ) -> RecoveryMetadataEnvelope? {
        let descriptor = open(
            snapshotPath,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        return recoveryMetadataEnvelope(
            forDescriptor: descriptor,
            expectedPath: snapshotPath
        )
    }

    private static func recoveryMetadataEnvelope(
        forDescriptor descriptor: Int32,
        expectedPath: String
    ) -> RecoveryMetadataEnvelope? {
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              initialStatus.st_mode & S_IFMT == S_IFREG,
              initialStatus.st_uid == geteuid(),
              initialStatus.st_nlink == 1,
              path(expectedPath, names: initialStatus) else {
            return nil
        }
        let byteCount = fgetxattr(
            descriptor,
            recoveryMetadataName,
            nil,
            0,
            0,
            0
        )
        guard byteCount > 0, byteCount <= maxRecoveryMetadataBytes else { return nil }
        var data = Data(count: byteCount)
        let bytesRead = data.withUnsafeMutableBytes { buffer in
            fgetxattr(
                descriptor,
                recoveryMetadataName,
                buffer.baseAddress,
                buffer.count,
                0,
                0
            )
        }
        var finalStatus = stat()
        guard bytesRead == byteCount,
              fstat(descriptor, &finalStatus) == 0,
              sameStableFile(finalStatus, initialStatus),
              path(expectedPath, names: finalStatus) else {
            return nil
        }
        guard let metadata = try? JSONDecoder().decode(RecoveryMetadata.self, from: data) else {
            return nil
        }
        return RecoveryMetadataEnvelope(metadata: metadata, byteCount: byteCount)
    }

    private static func writeRecoveryMetadataData(
        _ data: Data,
        atPath path: String
    ) -> Bool {
        let descriptor = open(
            path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        return writeRecoveryMetadataData(
            data,
            toDescriptor: descriptor,
            expectedPath: path
        )
    }

    /// Descriptor-bound metadata commit primitive. Keeping this internal lets
    /// callers that already hold an inode avoid reopening a mutable path.
    static func writeRecoveryMetadataData(
        _ data: Data,
        toDescriptor descriptor: Int32,
        expectedPath: String
    ) -> Bool {
        guard !data.isEmpty, data.count <= maxRecoveryMetadataBytes else {
            return false
        }
        var initialStatus = stat()
        guard fstat(descriptor, &initialStatus) == 0,
              initialStatus.st_mode & S_IFMT == S_IFREG,
              initialStatus.st_uid == geteuid(),
              initialStatus.st_nlink == 1,
              path(expectedPath, names: initialStatus),
              data.withUnsafeBytes({ buffer in
                fsetxattr(
                    descriptor,
                    recoveryMetadataName,
                    buffer.baseAddress,
                    buffer.count,
                    0,
                    0
                ) == 0
              }),
              fsync(descriptor) == 0 else {
            return false
        }
        var finalStatus = stat()
        return fstat(descriptor, &finalStatus) == 0
            && sameStableFile(finalStatus, initialStatus)
            && path(expectedPath, names: finalStatus)
    }

    private static func path(_ path: String, names expectedStatus: stat) -> Bool {
        var pathStatus = stat()
        return lstat(path, &pathStatus) == 0
            && pathStatus.st_mode & S_IFMT == S_IFREG
            && pathStatus.st_uid == geteuid()
            && pathStatus.st_nlink == 1
            && sameStableFile(pathStatus, expectedStatus)
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
        directoryStream: UnsafeMutablePointer<DIR>,
        maximumEntries: Int,
        afterTranscriptPath: String?,
        fileManager: FileManager,
        processProbeBudget: inout RecoveryProcessProbeBudget,
        cancellationCheck: @Sendable () -> Bool
    ) -> RecoveryCandidateScan {
        let standardizedSnapshotDirectory = (directory.path as NSString).standardizingPath
        var candidates: [PendingRecoverySnapshot] = []
        var candidateMetadataBytes = 0
        var candidateContentBytes: UInt64 = 0
        var budgetBlockedTranscriptPaths: Set<String> = []
        var invalidEntries: [URL] = []
        var examinedEntries = 0
        var reachedEnd = false
        while examinedEntries < max(0, maximumEntries),
              !cancellationCheck() {
            guard let entry = readdir(directoryStream) else {
                reachedEnd = true
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            examinedEntries += 1
            var url = directory.appendingPathComponent(name, isDirectory: false)
            var metadataEnvelope = recoveryMetadataEnvelope(atSnapshotPath: url.path)
            if name.hasPrefix(".") {
                guard name.contains("-capture-"), name.hasSuffix(".tmp") else {
                    continue
                }
                guard let stagedMetadata = metadataEnvelope?.metadata,
                      let publishedURL = publishStagedRecoveryCandidate(
                        url,
                        metadata: stagedMetadata,
                        in: directory
                      ) else {
                    if invalidEntries.count < maxStartupRecoveryInvalidMovesPerLaunch {
                        invalidEntries.append(url)
                    }
                    continue
                }
                url = publishedURL
                metadataEnvelope = recoveryMetadataEnvelope(
                    atSnapshotPath: publishedURL.path
                )
            }
            if !name.hasPrefix("."),
               (url.pathExtension != "jsonl" || metadataEnvelope == nil) {
                if invalidEntries.count < maxStartupRecoveryInvalidMovesPerLaunch {
                    invalidEntries.append(url)
                }
                continue
            }
            var status = stat()
            guard url.pathExtension == "jsonl",
                  lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_size >= 0,
                  UInt64(status.st_size) <= maximumProtectedTranscriptBytes,
                  let metadataEnvelope else {
                if !name.hasPrefix("."),
                   invalidEntries.count < maxStartupRecoveryInvalidMovesPerLaunch {
                    invalidEntries.append(url)
                }
                continue
            }
            if metadataEnvelope.metadata.version == 2,
               (metadataEnvelope.metadata.candidateState == "external-staging"
                || metadataEnvelope.metadata.candidateState
                    == "external-staging-pending") {
                _ = cleanupExternalRestoreStagingAuthority(
                    at: url,
                    fileManager: fileManager
                )
                continue
            }
            guard recoveryMetadata(
                metadataEnvelope.metadata,
                isValidAt: url
            ) else {
                if invalidEntries.count < maxStartupRecoveryInvalidMovesPerLaunch {
                    invalidEntries.append(url)
                }
                continue
            }
            let effectiveMetadataEnvelope: RecoveryMetadataEnvelope
            if metadataEnvelope.metadata.version == 1 {
                guard let upgraded = upgradeLegacyRecoveryMetadata(
                    metadataEnvelope.metadata,
                    at: url,
                    status: status
                ) else {
                    continue
                }
                effectiveMetadataEnvelope = upgraded
            } else {
                effectiveMetadataEnvelope = metadataEnvelope
            }
            let metadata = effectiveMetadataEnvelope.metadata
            guard
                  isSafeSessionIdPathComponent(metadata.sessionId),
                  snapshotFilenameMatchesSession(url, sessionId: metadata.sessionId),
                  metadata.transcriptPath.hasPrefix("/"),
                  !metadata.transcriptPath.contains("\0"),
                  (metadata.transcriptPath as NSString).standardizingPath !=
                    (url.path as NSString).standardizingPath else {
                if invalidEntries.count < maxStartupRecoveryInvalidMovesPerLaunch {
                    invalidEntries.append(url)
                }
                continue
            }
            let transcriptKey = (metadata.transcriptPath as NSString).standardizingPath
            guard !budgetBlockedTranscriptPaths.contains(transcriptKey),
                  transcriptKey != standardizedSnapshotDirectory,
                  !transcriptKey.hasPrefix(standardizedSnapshotDirectory + "/"),
                  transcriptDestinationIsRegularOrMissing(
                    metadata.transcriptPath,
                    fileManager: fileManager
                  ) else {
                continue
            }
            guard recoveryMetadataOwnerState(
                metadata,
                processProbeBudget: &processProbeBudget
            ) == .retired else {
                // A live or unprobed generation blocks every older generation
                // for the same transcript. Dropping only that candidate would
                // let stale bytes win merely because the syscall budget ended.
                budgetBlockedTranscriptPaths.insert(transcriptKey)
                candidates.removeAll {
                    ($0.metadata.transcriptPath as NSString).standardizingPath
                        == transcriptKey
                }
                candidateMetadataBytes = candidates.reduce(0) {
                    $0 + $1.metadataByteCount
                }
                candidateContentBytes = candidates.reduce(0) {
                    $0 + $1.contentByteCount
                }
                continue
            }
            guard let content = recoveryContent(
                for: metadata,
                authorityURL: url,
                authorityStatus: status
            ) else {
                // A split cross-volume authority is valid only when both
                // metadata copies still describe the exact same generation.
                // Preserve a mismatched pointer in quarantine instead of
                // silently retrying weakened external authority forever.
                if invalidEntries.count < maxStartupRecoveryInvalidMovesPerLaunch {
                    invalidEntries.append(url)
                }
                continue
            }
            guard let authorityVersion = stableRegularFileVersion(
                    atPath: url.path,
                    fileManager: fileManager
                  ),
                  let contentVersion = content.url.path == url.path
                    ? authorityVersion
                    : stableRegularFileVersion(
                        atPath: content.url.path,
                        fileManager: fileManager
                      ),
                  recoveryMetadata(atSnapshotPath: url.path) == metadata else {
                continue
            }
            let modificationDate = Date(
                timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                    + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
            )
            let capturedAt = recoveryOrderingDate(
                metadata.capturedAt ?? modificationDate,
                fallback: modificationDate
            )
            insertRecoveryCandidate(
                PendingRecoverySnapshot(
                url: url,
                contentURL: content.url,
                authorityVersion: authorityVersion,
                contentVersion: contentVersion,
                metadata: metadata,
                metadataByteCount: effectiveMetadataEnvelope.byteCount,
                contentByteCount: UInt64(content.status.st_size),
                capturedAt: capturedAt,
                modificationDate: modificationDate
                ),
                into: &candidates,
                metadataBytes: &candidateMetadataBytes,
                contentBytes: &candidateContentBytes,
                budgetBlockedTranscriptPaths: &budgetBlockedTranscriptPaths,
                afterTranscriptPath: afterTranscriptPath
            )
        }
        return RecoveryCandidateScan(
            candidates: candidates,
            budgetBlockedTranscriptPaths: budgetBlockedTranscriptPaths,
            invalidEntries: invalidEntries,
            examinedEntries: examinedEntries,
            reachedEnd: reachedEnd
        )
    }

    private static func upgradeLegacyRecoveryMetadata(
        _ metadata: RecoveryMetadata,
        at candidateURL: URL,
        status: stat
    ) -> RecoveryMetadataEnvelope? {
        guard metadata.version == 1,
              recoveryMetadata(metadata, isValidAt: candidateURL) else {
            return nil
        }
        let capturedAt = metadata.capturedAt ?? Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        let snapshot = TeardownTranscriptSnapshot(
            transcriptPath: metadata.transcriptPath,
            snapshotPath: candidateURL.path,
            liveFileVersion: metadata.liveFileVersion,
            guardedProcessIdentities: metadata.guardedProcesses?
                .compactMap(\.processIdentity) ?? [],
            hasUncapturedGuardedProcesses:
                metadata.hasUncapturedGuardedProcesses == true
        )
        guard persistRecoveryMetadata(
            for: snapshot,
            sessionId: metadata.sessionId,
            capturedAt: capturedAt,
            liveFileVersion: metadata.liveFileVersion,
            ownerProcessIdentity: metadata.ownerProcessIdentity,
            ownerRuntimeMetadata: .init(
                runtimeId: metadata.ownerRuntimeId,
                bundleIdentifier: metadata.ownerBundleIdentifier
            ),
            guardedProcessIdentities: snapshot.guardedProcessIdentities,
            hasUncapturedGuardedProcesses:
                snapshot.hasUncapturedGuardedProcesses
        ), synchronizeRegularFileAndContainingDirectory(atPath: candidateURL.path),
              let upgraded = recoveryMetadataEnvelope(
                atSnapshotPath: candidateURL.path
              ),
              upgraded.metadata.version == 2,
              recoveryMetadata(upgraded.metadata, isValidAt: candidateURL) else {
            return nil
        }
        return upgraded
    }

    private static func validatedDurableRetainedMetadata(
        at retainedURL: URL,
        fileManager: FileManager
    ) -> RecoveryMetadata? {
        guard let envelope = recoveryMetadataEnvelope(
            atSnapshotPath: retainedURL.path
        ) else {
            return nil
        }
        switch envelope.metadata.version {
        case 1:
            var status = stat()
            guard lstat(retainedURL.path, &status) == 0 else { return nil }
            return upgradeLegacyRecoveryMetadata(
                envelope.metadata,
                at: retainedURL,
                status: status
            )?.metadata
        case 2:
            guard recoveryMetadata(envelope.metadata, isValidAt: retainedURL),
                  synchronizeRegularFileAndContainingDirectory(
                    atPath: retainedURL.path
                  ),
                  recoveryMetadataEnvelope(
                    atSnapshotPath: retainedURL.path
                  )?.metadata == envelope.metadata else {
                return nil
            }
            return envelope.metadata
        default:
            return nil
        }
    }

    private static func insertRecoveryCandidate(
        _ candidate: PendingRecoverySnapshot,
        into candidates: inout [PendingRecoverySnapshot],
        metadataBytes: inout Int,
        contentBytes: inout UInt64,
        budgetBlockedTranscriptPaths: inout Set<String>,
        afterTranscriptPath: String?
    ) {
        let selection = selectRecoveryCandidatesUnderBudget(
            candidates + [candidate],
            transcriptKey: {
                ($0.metadata.transcriptPath as NSString).standardizingPath
            },
            metadataByteCount: \.metadataByteCount,
            contentByteCount: \.contentByteCount,
            isNewer: recoveryCandidateIsNewer,
            maximumCount: maxStartupRecoverySnapshots,
            maximumMetadataBytes: maxStartupRecoveryCandidateMetadataBytes,
            maximumContentBytes: maxStartupRecoveryCandidateContentBytes,
            previouslyBlockedTranscriptKeys: budgetBlockedTranscriptPaths,
            afterTranscriptPath: afterTranscriptPath
        )
        candidates = selection.candidates
        budgetBlockedTranscriptPaths = selection.blockedTranscriptKeys
        metadataBytes = candidates.reduce(0) { $0 + $1.metadataByteCount }
        contentBytes = candidates.reduce(0) { $0 + $1.contentByteCount }
    }

    /// Selects complete transcript-generation groups under startup's bounded
    /// memory budget. If any generation of a transcript cannot be represented,
    /// the whole transcript is deferred. This preserves the invariant that an
    /// unresolved newer generation can never be forgotten while an older one is
    /// admitted from a later directory batch.
    static func selectRecoveryCandidatesUnderBudget<Candidate>(
        _ input: [Candidate],
        transcriptKey: (Candidate) -> String,
        metadataByteCount: (Candidate) -> Int,
        contentByteCount: (Candidate) -> UInt64,
        isNewer: (Candidate, Candidate) -> Bool,
        maximumCount: Int,
        maximumMetadataBytes: Int,
        maximumContentBytes: UInt64,
        previouslyBlockedTranscriptKeys: Set<String> = [],
        afterTranscriptPath: String? = nil
    ) -> (candidates: [Candidate], blockedTranscriptKeys: Set<String>) {
        var blockedTranscriptKeys = previouslyBlockedTranscriptKeys
        var candidatesByTranscript: [String: [Candidate]] = [:]
        for candidate in input {
            let key = transcriptKey(candidate)
            guard !blockedTranscriptKeys.contains(key) else { continue }
            candidatesByTranscript[key, default: []].append(candidate)
        }
        for key in Array(candidatesByTranscript.keys) {
            candidatesByTranscript[key]?.sort(by: isNewer)
        }
        let orderedKeys = candidatesByTranscript.keys.sorted {
            recoveryTranscriptKey($0, precedes: $1, after: afterTranscriptPath)
        }

        var selected: [(key: String, candidate: Candidate)] = []
        var selectedMetadataBytes = 0
        var selectedContentBytes: UInt64 = 0
        var generationIndex = 0
        while selected.count < max(0, maximumCount) {
            var examinedGeneration = false
            for key in orderedKeys
            where selected.count < max(0, maximumCount)
                && !blockedTranscriptKeys.contains(key) {
                guard let values = candidatesByTranscript[key],
                      generationIndex < values.count else {
                    continue
                }
                examinedGeneration = true
                let candidate = values[generationIndex]
                let candidateMetadataBytes = metadataByteCount(candidate)
                let candidateContentBytes = contentByteCount(candidate)
                guard candidateMetadataBytes >= 0,
                      candidateMetadataBytes <= maximumMetadataBytes,
                      candidateContentBytes <= maximumContentBytes,
                      selectedMetadataBytes <= maximumMetadataBytes - candidateMetadataBytes,
                      selectedContentBytes <= maximumContentBytes - candidateContentBytes else {
                    blockedTranscriptKeys.insert(key)
                    selected.removeAll { selectedCandidate in
                        guard selectedCandidate.key == key else { return false }
                        selectedMetadataBytes -= metadataByteCount(selectedCandidate.candidate)
                        selectedContentBytes -= contentByteCount(selectedCandidate.candidate)
                        return true
                    }
                    continue
                }
                selected.append((key, candidate))
                selectedMetadataBytes += candidateMetadataBytes
                selectedContentBytes += candidateContentBytes
            }
            guard examinedGeneration else { break }
            generationIndex += 1
        }

        let selectedCountByTranscript = Dictionary(
            grouping: selected,
            by: \.key
        ).mapValues(\.count)
        for (key, values) in candidatesByTranscript
        where selectedCountByTranscript[key, default: 0] < values.count {
            blockedTranscriptKeys.insert(key)
        }
        selected.removeAll { blockedTranscriptKeys.contains($0.key) }
        return (selected.map(\.candidate), blockedTranscriptKeys)
    }

    private static func recoveryTranscriptKey(
        _ lhs: String,
        precedes rhs: String,
        after cursor: String?
    ) -> Bool {
        guard lhs != rhs else { return false }
        guard let cursor else { return lhs < rhs }
        let lhsFollowsCursor = lhs > cursor
        let rhsFollowsCursor = rhs > cursor
        if lhsFollowsCursor != rhsFollowsCursor {
            return lhsFollowsCursor
        }
        return lhs < rhs
    }

    /// A completed hidden capture is already durable recovery authority. A
    /// crash can occur after its metadata fsync but before the normal publish
    /// rename, so startup must publish it instead of pruning it as a temp.
    private static func publishStagedRecoveryCandidate(
        _ stagedURL: URL,
        metadata: RecoveryMetadata,
        in directory: URL
    ) -> URL? {
        let standardizedDirectory = (directory.path as NSString).standardizingPath
        guard isSafeSessionIdPathComponent(metadata.sessionId) else { return nil }
        var effectiveMetadata = metadata
        let intendedURL: URL
        switch metadata.version {
        case 1:
            guard let snapshotPath = metadata.snapshotPath else { return nil }
            intendedURL = URL(fileURLWithPath: snapshotPath)
            guard (intendedURL.deletingLastPathComponent().path as NSString).standardizingPath
                    == standardizedDirectory,
                  snapshotFilenameMatchesSession(
                    intendedURL,
                    sessionId: metadata.sessionId
                  ) else {
                return nil
            }
        case 2:
            guard let candidateId = metadata.candidateId,
                  UUID(uuidString: candidateId) != nil,
                  metadata.candidateState == "recoverable" else {
                return nil
            }
            intendedURL = directory.appendingPathComponent(
                "\(metadata.sessionId)-\(candidateId).jsonl",
                isDirectory: false
            )
        default:
            return nil
        }
        var intendedStatus = stat()
        let destinationURL: URL
        if lstat(intendedURL.path, &intendedStatus) == 0 {
            destinationURL = directory.appendingPathComponent(
                "\(metadata.sessionId)-staged-\(UUID().uuidString).jsonl",
                isDirectory: false
            )
        } else {
            guard errno == ENOENT else { return nil }
            destinationURL = intendedURL
        }
        if metadata.version == 1, destinationURL.path != intendedURL.path {
            let stagedSnapshot = TeardownTranscriptSnapshot(
                transcriptPath: metadata.transcriptPath,
                snapshotPath: stagedURL.path,
                liveFileVersion: metadata.liveFileVersion,
                guardedProcessIdentities: metadata.guardedProcesses?.compactMap(\.processIdentity) ?? [],
                hasUncapturedGuardedProcesses: metadata.hasUncapturedGuardedProcesses == true
            )
            guard persistRecoveryMetadata(
                for: stagedSnapshot,
                sessionId: metadata.sessionId,
                capturedAt: metadata.capturedAt ?? Date(),
                liveFileVersion: metadata.liveFileVersion,
                ownerProcessIdentity: metadata.ownerProcessIdentity,
                ownerRuntimeMetadata: .init(
                    runtimeId: metadata.ownerRuntimeId,
                    bundleIdentifier: metadata.ownerBundleIdentifier
                ),
                guardedProcessIdentities: stagedSnapshot.guardedProcessIdentities,
                hasUncapturedGuardedProcesses: stagedSnapshot.hasUncapturedGuardedProcesses
            ), synchronizeRegularFileAndContainingDirectory(atPath: stagedURL.path),
                  let upgraded = recoveryMetadata(atSnapshotPath: stagedURL.path) else {
                return nil
            }
            effectiveMetadata = upgraded
        }
        guard renamex_np(
            stagedURL.path,
            destinationURL.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            return nil
        }
        guard recoveryMetadata(effectiveMetadata, isValidAt: destinationURL),
              synchronizeRegularFileAndContainingDirectory(atPath: destinationURL.path) else {
            _ = renamex_np(
                destinationURL.path,
                stagedURL.path,
                UInt32(RENAME_EXCL)
            )
            return nil
        }
        return destinationURL
    }

    private static func recoveryMetadata(
        _ metadata: RecoveryMetadata,
        isValidAt candidateURL: URL
    ) -> Bool {
        switch metadata.version {
        case 1:
            guard let snapshotPath = metadata.snapshotPath else { return false }
            return (snapshotPath as NSString).standardizingPath ==
                (candidateURL.path as NSString).standardizingPath
                && metadata.externalCandidatePath == nil
                && metadata.externalFileDevice == nil
                && metadata.externalFileNumber == nil
        case 2:
            guard let candidateId = metadata.candidateId else { return false }
            let hasExternalPath = metadata.externalCandidatePath != nil
            let hasExternalDevice = metadata.externalFileDevice != nil
            let hasExternalFile = metadata.externalFileNumber != nil
            return UUID(uuidString: candidateId) != nil
                && metadata.candidateState == "recoverable"
                && metadata.snapshotPath == nil
                && (hasExternalPath == hasExternalDevice)
                && (hasExternalPath == hasExternalFile)
        default:
            return false
        }
    }

    private static func recoveryContent(
        for metadata: RecoveryMetadata,
        authorityURL: URL,
        authorityStatus: stat
    ) -> (url: URL, status: stat)? {
        guard let externalPath = metadata.externalCandidatePath else {
            return (authorityURL, authorityStatus)
        }
        guard let candidateId = metadata.candidateId,
              UUID(uuidString: candidateId) != nil,
              externalPath.hasPrefix("/"),
              !externalPath.contains("\0"),
              (externalPath as NSString).standardizingPath !=
                (authorityURL.path as NSString).standardizingPath,
              let expectedDevice = metadata.externalFileDevice,
              let expectedFile = metadata.externalFileNumber else {
            return nil
        }
        let transcriptURL = URL(fileURLWithPath: metadata.transcriptPath)
        let expectedExternalURL = transcriptURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(transcriptURL.lastPathComponent).cmux-recovery-\(candidateId).jsonl",
                isDirectory: false
            )
        guard (externalPath as NSString).standardizingPath
                == (expectedExternalURL.path as NSString).standardizingPath else {
            return nil
        }
        let externalURL = URL(fileURLWithPath: externalPath)
        var externalStatus = stat()
        guard lstat(externalURL.path, &externalStatus) == 0,
              externalStatus.st_mode & S_IFMT == S_IFREG,
              externalStatus.st_uid == geteuid(),
              externalStatus.st_nlink == 1,
              externalStatus.st_size >= 0,
              UInt64(externalStatus.st_size) <= maximumProtectedTranscriptBytes,
              UInt64(externalStatus.st_dev) == expectedDevice,
              UInt64(externalStatus.st_ino) == expectedFile,
              let externalMetadata = recoveryMetadata(
                atSnapshotPath: externalURL.path
              ),
              externalMetadata == metadata,
              recoveryMetadata(externalMetadata, isValidAt: externalURL) else {
            return nil
        }
        return (externalURL, externalStatus)
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

    private static func recoveryOrderingDate(_ date: Date, fallback: Date) -> Date {
        let maximumMagnitude: TimeInterval = 100_000_000_000
        let fallbackSeconds = fallback.timeIntervalSinceReferenceDate
        let seconds = date.timeIntervalSinceReferenceDate
        let finiteSeconds = seconds.isFinite
            ? seconds
            : (fallbackSeconds.isFinite ? fallbackSeconds : 0)
        return Date(
            timeIntervalSinceReferenceDate: min(
                maximumMagnitude,
                max(-maximumMagnitude, finiteSeconds)
            )
        )
    }

    private static func recoveryMetadataOwnerState(
        _ metadata: RecoveryMetadata,
        processProbeBudget: inout RecoveryProcessProbeBudget
    ) -> RecoveryOwnerState {
        if metadata.hasUncapturedGuardedProcesses == true { return .live }
        if metadata.ownerProcessId != nil
            || metadata.ownerProcessStartSeconds != nil
            || metadata.ownerProcessStartMicroseconds != nil {
            guard let ownerIdentity = metadata.ownerProcessIdentity else {
                return .unknown
            }
            let current = processProbeBudget.identity(for: ownerIdentity.pid)
            guard current.known else { return .unknown }
            if current.identity == ownerIdentity { return .live }
        }
        if let ownerRuntimeId = metadata.ownerRuntimeId,
           ownerRuntimeId == normalized(
            ProcessInfo.processInfo.environment["CMUX_RUNTIME_ID"]
           ),
           metadata.ownerBundleIdentifier == Bundle.main.bundleIdentifier {
            return .live
        }
        for guarded in (metadata.guardedProcesses ?? []).prefix(64) {
            guard let identity = guarded.processIdentity else { return .unknown }
            let current = processProbeBudget.identity(for: identity.pid)
            guard current.known else { return .unknown }
            if current.identity == identity { return .live }
        }
        return .retired
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
        guard let descriptor = validatedRecoveryDirectoryLockDescriptor(in: directory) else {
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        return descriptor
    }

    private static func acquireRecoveryDirectoryLockSynchronously(
        in directory: URL
    ) -> Int32? {
        guard let descriptor = validatedRecoveryDirectoryLockDescriptor(in: directory) else {
            return nil
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                return nil
            }
        }
        _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
        return descriptor
    }

    private static func acquireRecoveryDirectoryLockAwaitingContention(
        in directory: URL
    ) async -> Int32? {
        await withCheckedContinuation { continuation in
            recoveryLockWaitQueue.async {
                guard let descriptor = validatedRecoveryDirectoryLockDescriptor(
                    in: directory
                ) else {
                    continuation.resume(returning: nil)
                    return
                }
                while flock(descriptor, LOCK_EX) != 0 {
                    guard errno == EINTR else {
                        close(descriptor)
                        continuation.resume(returning: nil)
                        return
                    }
                }
                _ = fchmod(descriptor, S_IRUSR | S_IWUSR)
                continuation.resume(returning: descriptor)
            }
        }
    }

    private static func validatedRecoveryDirectoryLockDescriptor(
        in directory: URL
    ) -> Int32? {
        guard ensurePrivateRecoveryDirectory(
            at: directory,
            createIfMissing: false,
            fileManager: .default
        ) else { return nil }
        let lockURL = directory.appendingPathComponent(recoveryLockFilename, isDirectory: false)
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func releaseRecoveryDirectoryLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    /// Counts every recovery file before admitting another durable authority.
    /// The scan is complete when under quota and short-circuits as soon as a
    /// limit is exceeded, so directory noise cannot force unbounded allocation.
    /// Cross-volume content is counted by inode in addition to its pointer.
    private static func recoveryStorageCanAdmit(
        in directory: URL,
        additionalFileCount: Int,
        additionalBytes: UInt64,
        maximumFileCount: Int,
        maximumBytes: UInt64
    ) -> Bool {
        guard maximumFileCount >= 0,
              additionalFileCount >= 0,
              additionalFileCount <= maximumFileCount,
              additionalBytes <= maximumBytes else {
            return false
        }
        var fileCount = additionalFileCount
        var logicalBytes = additionalBytes
        var countedFiles: Set<RecoveryStorageFileIdentity> = []

        func addFile(_ status: stat) -> Bool {
            guard status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_size >= 0 else {
                return false
            }
            let identity = RecoveryStorageFileIdentity(status)
            guard countedFiles.insert(identity).inserted else { return true }
            let size = UInt64(status.st_size)
            guard size <= maximumBytes,
                  fileCount < maximumFileCount,
                  logicalBytes <= maximumBytes - size else {
                return false
            }
            fileCount += 1
            logicalBytes += size
            return true
        }

        func addReferencedExternalFile(
            metadata: RecoveryMetadata,
            authorityURL: URL,
            authorityStatus: stat
        ) -> Bool {
            guard let externalPath = metadata.externalCandidatePath else {
                return true
            }
            if let content = recoveryContent(
                for: metadata,
                authorityURL: authorityURL,
                authorityStatus: authorityStatus
            ) {
                return addFile(content.status)
            }

            // Invalid split metadata is not recovery authority, but its exact
            // referenced inode still consumes storage. Count it conservatively
            // when the pointer's path, device, and inode tuple is self-consistent.
            guard let candidateId = metadata.candidateId,
                  UUID(uuidString: candidateId) != nil,
                  externalPath.hasPrefix("/"),
                  !externalPath.contains("\0"),
                  let expectedDevice = metadata.externalFileDevice,
                  let expectedFile = metadata.externalFileNumber else {
                return false
            }
            let transcriptURL = URL(fileURLWithPath: metadata.transcriptPath)
            let expectedURL = transcriptURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(transcriptURL.lastPathComponent).cmux-recovery-\(candidateId).jsonl",
                    isDirectory: false
                )
            guard (externalPath as NSString).standardizingPath
                    == (expectedURL.path as NSString).standardizingPath else {
                return false
            }
            var externalStatus = stat()
            guard lstat(externalPath, &externalStatus) == 0,
                  UInt64(externalStatus.st_dev) == expectedDevice,
                  UInt64(externalStatus.st_ino) == expectedFile else {
                return false
            }
            return addFile(externalStatus)
        }

        func scanDirectory(
            _ scanDirectoryURL: URL,
            permitsQuarantineChild: Bool
        ) -> Bool {
            guard let stream = recoveryDirectoryStream(in: scanDirectoryURL) else {
                return false
            }
            defer { closedir(stream) }
            while let entry = readdir(stream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
                    namePointer.withMemoryRebound(
                        to: CChar.self,
                        capacity: Int(entry.pointee.d_namlen) + 1
                    ) { String(cString: $0) }
                }
                guard name != ".", name != ".." else { continue }
                if permitsQuarantineChild, name == recoveryLockFilename { continue }
                guard !name.isEmpty, !name.contains("/") else { return false }
                var status = stat()
                guard fstatat(
                    dirfd(stream),
                    name,
                    &status,
                    AT_SYMLINK_NOFOLLOW
                ) == 0 else {
                    return false
                }
                let url = scanDirectoryURL.appendingPathComponent(
                    name,
                    isDirectory: status.st_mode & S_IFMT == S_IFDIR
                )
                if status.st_mode & S_IFMT == S_IFDIR {
                    guard permitsQuarantineChild,
                          name == ".recovery-quarantine",
                          status.st_uid == geteuid(),
                          scanDirectory(url, permitsQuarantineChild: false) else {
                        return false
                    }
                    continue
                }
                guard addFile(status) else { return false }

                if let metadata = recoveryMetadataEnvelope(
                    atSnapshotPath: url.path
                )?.metadata {
                    guard addReferencedExternalFile(
                        metadata: metadata,
                        authorityURL: url,
                        authorityStatus: status
                    ) else {
                        return false
                    }
                } else if name.contains("-pointer-") {
                    // A malformed ordinary candidate is fully accounted by its
                    // own bytes. A pointer may hide an external inode, so
                    // admission fails closed until startup quarantines it.
                    return false
                }
            }
            return true
        }

        return scanDirectory(directory, permitsQuarantineChild: true)
    }

    private static func recoveryCursor(lockDescriptor: Int32) -> RecoveryCursorState {
        let handle = FileHandle(fileDescriptor: lockDescriptor, closeOnDealloc: false)
        do {
            try handle.seek(toOffset: 0)
            guard let data = try handle.read(upToCount: maxRecoveryCursorBytes + 1),
                  !data.isEmpty,
                  data.count <= maxRecoveryCursorBytes,
                  let value = String(data: data, encoding: .utf8),
                  !value.contains("\0") else {
                return RecoveryCursorState(transcriptPath: nil)
            }
            if let state = try? JSONDecoder().decode(RecoveryCursorState.self, from: data) {
                return state
            }
            // Version-one lock files stored only the transcript fairness key.
            return RecoveryCursorState(transcriptPath: value)
        } catch {
            return RecoveryCursorState(transcriptPath: nil)
        }
    }

    private static func persistRecoveryCursor(
        _ cursor: RecoveryCursorState,
        lockDescriptor: Int32
    ) {
        guard let data = try? JSONEncoder().encode(cursor),
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
        _ candidate: PendingRecoverySnapshot,
        fileManager: FileManager
    ) -> PendingRecoverySnapshot? {
        guard candidate.metadata.version == 2,
              recoveryMetadata(candidate.metadata, isValidAt: candidate.url),
              stableRegularFileVersion(
                atPath: candidate.url.path,
                fileManager: fileManager
              ) == candidate.authorityVersion,
              stableRegularFileVersion(
                atPath: candidate.contentURL.path,
                fileManager: fileManager
              ) == candidate.contentVersion,
              recoveryMetadata(atSnapshotPath: candidate.url.path)
                == candidate.metadata else {
            return nil
        }
        let claimedURL = candidate.url.deletingLastPathComponent()
            .appendingPathComponent(
                "\(candidate.metadata.sessionId)-processing-\(UUID().uuidString).jsonl",
                isDirectory: false
            )
        guard atomicallyRename(candidate.url, to: claimedURL) else { return nil }
        let claimedContentURL = candidate.contentURL.path == candidate.url.path
            ? claimedURL
            : candidate.contentURL
        var claimedAuthorityStatus = stat()
        guard stableRegularFileVersion(
                atPath: claimedURL.path,
                fileManager: fileManager
              ) == candidate.authorityVersion,
              stableRegularFileVersion(
                atPath: claimedContentURL.path,
                fileManager: fileManager
              ) == candidate.contentVersion,
              recoveryMetadata(atSnapshotPath: claimedURL.path)
                == candidate.metadata,
              lstat(claimedURL.path, &claimedAuthorityStatus) == 0,
              let validatedContent = recoveryContent(
                for: candidate.metadata,
                authorityURL: claimedURL,
                authorityStatus: claimedAuthorityStatus
              ),
              validatedContent.url.path == claimedContentURL.path else {
            _ = atomicallyRename(claimedURL, to: candidate.url)
            return nil
        }
        return PendingRecoverySnapshot(
            url: claimedURL,
            contentURL: claimedContentURL,
            authorityVersion: candidate.authorityVersion,
            contentVersion: candidate.contentVersion,
            metadata: candidate.metadata,
            metadataByteCount: candidate.metadataByteCount,
            contentByteCount: candidate.contentByteCount,
            capturedAt: candidate.capturedAt,
            modificationDate: candidate.modificationDate
        )
    }

    private static func durablyRemoveClaimedRecoveryCandidate(
        _ candidate: PendingRecoverySnapshot,
        authorityVersion: TeardownTranscriptFileVersion,
        contentVersion: TeardownTranscriptFileVersion,
        afterSynchronizingLivePath livePath: String?
    ) -> Bool {
        if candidate.contentURL.path != candidate.url.path {
            guard durablyRemoveRecoverySnapshot(
                atPath: candidate.contentURL.path,
                afterSynchronizingLivePath: livePath,
                expectedSnapshotVersion: contentVersion
            ) else {
                return false
            }
        }
        return durablyRemoveRecoverySnapshot(
            atPath: candidate.url.path,
            afterSynchronizingLivePath: livePath,
            expectedSnapshotVersion: authorityVersion
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
            ownerProcessIdentity: candidate.metadata.ownerProcessIdentity,
            ownerRuntimeMetadata: .init(
                runtimeId: candidate.metadata.ownerRuntimeId,
                bundleIdentifier: candidate.metadata.ownerBundleIdentifier
            ),
            guardedProcessIdentities: candidate.metadata.guardedProcesses?.compactMap(\.processIdentity) ?? [],
            hasUncapturedGuardedProcesses:
                candidate.metadata.hasUncapturedGuardedProcesses == true,
            candidateId: candidate.metadata.candidateId,
            externalCandidatePath: candidate.metadata.externalCandidatePath,
            externalFileDevice: candidate.metadata.externalFileDevice,
            externalFileNumber: candidate.metadata.externalFileNumber
        )
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: preservedURL.path)
        _ = synchronizeRegularFileAndContainingDirectory(atPath: preservedURL.path)
    }

    private static func moveInvalidRecoveryEntriesAside(
        _ entries: [URL],
        in directory: URL,
        fileManager: FileManager,
        cancellationCheck: @Sendable () -> Bool
    ) {
        guard !entries.isEmpty, !cancellationCheck() else { return }
        let quarantineDirectory = directory.appendingPathComponent(
            ".recovery-quarantine",
            isDirectory: true
        )
        guard ensurePrivateRecoveryDirectory(
            at: quarantineDirectory,
            createIfMissing: true,
            fileManager: fileManager
        ) else { return }
        var movedAny = false
        for entry in entries.prefix(maxStartupRecoveryInvalidMovesPerLaunch) {
            guard !cancellationCheck() else { break }
            let name = entry.lastPathComponent
            guard name != recoveryLockFilename,
                  name != ".recovery-quarantine",
                  !name.isEmpty,
                  !name.contains("/") else {
                continue
            }
            var status = stat()
            guard lstat(entry.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1 else {
                continue
            }
            let destination = quarantineDirectory.appendingPathComponent(
                "invalid-\(UUID().uuidString)-\(name)",
                isDirectory: false
            )
            if atomicallyRename(entry, to: destination) { movedAny = true }
        }
        if movedAny {
            _ = synchronizeDirectory(atPath: directory.path)
            _ = synchronizeDirectory(atPath: quarantineDirectory.path)
        }
    }

    static func atomicallyRename(_ source: URL, to destination: URL) -> Bool {
        renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0
    }

    static func volumeSupportsAtomicSwap(in directory: URL) -> Bool {
        let directoryDescriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { return false }
        defer { Darwin.close(directoryDescriptor) }
        var directoryStatus = stat()
        guard fstat(directoryDescriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              directoryStatus.st_uid == geteuid() else {
            return false
        }
        let device = UInt64(directoryStatus.st_dev)
        if let cached = atomicSwapCapabilityCache.withLock({ $0[device] }) {
            return cached
        }

        let token = UUID().uuidString
        let firstName = ".cmux-swap-probe-a-\(token)"
        let secondName = ".cmux-swap-probe-b-\(token)"
        let firstURL = directory.appendingPathComponent(firstName)
        let secondURL = directory.appendingPathComponent(secondName)
        let firstDescriptor = openat(
            directoryDescriptor,
            firstName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard firstDescriptor >= 0 else { return false }
        defer {
            Darwin.close(firstDescriptor)
            _ = unlinkat(directoryDescriptor, firstName, 0)
        }
        let secondDescriptor = openat(
            directoryDescriptor,
            secondName,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard secondDescriptor >= 0 else { return false }
        defer {
            Darwin.close(secondDescriptor)
            _ = unlinkat(directoryDescriptor, secondName, 0)
            _ = fsync(directoryDescriptor)
        }
        var firstStatus = stat()
        var secondStatus = stat()
        guard fstat(firstDescriptor, &firstStatus) == 0,
              fstat(secondDescriptor, &secondStatus) == 0,
              fsync(firstDescriptor) == 0,
              fsync(secondDescriptor) == 0,
              fsync(directoryDescriptor) == 0,
              renamex_np(
                firstURL.path,
                secondURL.path,
                UInt32(RENAME_SWAP)
              ) == 0 else {
            return false
        }
        var swappedFirstStatus = stat()
        var swappedSecondStatus = stat()
        let supported = lstat(firstURL.path, &swappedFirstStatus) == 0
            && lstat(secondURL.path, &swappedSecondStatus) == 0
            && swappedFirstStatus.st_dev == secondStatus.st_dev
            && swappedFirstStatus.st_ino == secondStatus.st_ino
            && swappedSecondStatus.st_dev == firstStatus.st_dev
            && swappedSecondStatus.st_ino == firstStatus.st_ino
            && fsync(directoryDescriptor) == 0
        // Cache only a positive capability proof. Permission, fsync, and I/O
        // failures are transient and must not disable recovery for the whole
        // volume until process restart. Concurrent positive probes are
        // idempotent because each uses unique names and the cache lock only
        // publishes the final true result.
        if supported {
            atomicSwapCapabilityCache.withLock { $0[device] = true }
        }
        return supported
    }

    private static func defaultSnapshotDirectoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-transcript-teardown-snapshots", isDirectory: true)
    }

    private static func pruneOldSnapshots(in directory: URL, fileManager: FileManager) {
        pruneAbandonedCaptureTemps(in: directory)
        // Top-level snapshots are unresolved recovery authority. Age alone
        // never proves their bytes reached the live transcript, so pruning is
        // restricted to candidates already quarantined as invalid.
        let quarantineDirectory = directory.appendingPathComponent(
            ".recovery-quarantine",
            isDirectory: true
        )
        guard ensurePrivateRecoveryDirectory(
            at: quarantineDirectory,
            createIfMissing: false,
            fileManager: fileManager
        ) else { return }
        let descriptor = open(
            quarantineDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0, let stream = fdopendir(descriptor) else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return
        }
        defer { closedir(stream) }
        var examinedEntries = 0
        var removedAny = false
        while examinedEntries < maxStartupRecoveryDirectoryEntries,
              let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            examinedEntries += 1
            let url = quarantineDirectory.appendingPathComponent(name, isDirectory: false)
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  recoveryMetadataEnvelope(atSnapshotPath: url.path) == nil,
                  Darwin.unlink(url.path) == 0 else {
                continue
            }
            // Only metadata-free directory noise is disposable. A quarantined
            // recovery inode keeps its metadata because a late held-fd append
            // can turn a previously empty stub into the sole surviving branch.
            removedAny = true
        }
        if removedAny { _ = fsync(dirfd(stream)) }
    }

    private static func pruneAbandonedCaptureTemps(in directory: URL) {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0, let stream = fdopendir(descriptor) else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return
        }
        defer { closedir(stream) }
        let cutoff = Date().addingTimeInterval(-60 * 60).timeIntervalSince1970
        var examinedEntries = 0
        var removedAny = false
        while examinedEntries < maxStartupRecoveryDirectoryEntries,
              let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { namePointer in
                namePointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            examinedEntries += 1
            guard name.hasPrefix("."), name.contains("-capture-"), name.hasSuffix(".tmp") else {
                continue
            }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            // Metadata is written only after the stable copy is complete. Such
            // a temp is durable recovery authority after a crash and must be
            // published by startup recovery, never garbage-collected.
            guard recoveryMetadata(atSnapshotPath: url.path) == nil else { continue }
            var status = stat()
            guard lstat(url.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  TimeInterval(status.st_mtimespec.tv_sec) < cutoff,
                  Darwin.unlink(url.path) == 0 else {
                continue
            }
            removedAny = true
        }
        if removedAny { _ = fsync(dirfd(stream)) }
    }

    private static func ensurePrivateRecoveryDirectory(
        at directory: URL,
        createIfMissing: Bool,
        fileManager: FileManager
    ) -> Bool {
        var initialStatus = stat()
        let existed = lstat(directory.path, &initialStatus) == 0
        if !existed {
            guard createIfMissing else { return false }
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                )
            } catch {
                return false
            }
        }
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var status = stat()
        var pathStatus = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              fchmod(descriptor, mode_t(S_IRWXU)) == 0,
              lstat(directory.path, &pathStatus) == 0,
              pathStatus.st_mode & S_IFMT == S_IFDIR,
              pathStatus.st_uid == geteuid(),
              pathStatus.st_dev == status.st_dev,
              pathStatus.st_ino == status.st_ino else {
            return false
        }
        return existed || synchronizeContainingDirectory(atPath: directory.path)
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

    static func appendLiveStubIfPresent(
        from stubURL: URL,
        toRestoreFile restoreURL: URL,
        fileManager: FileManager
    ) throws {
        var initialPathStatus = stat()
        guard lstat(stubURL.path, &initialPathStatus) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(.EIO)
        }
        guard initialPathStatus.st_mode & S_IFMT == S_IFREG,
              initialPathStatus.st_size >= 0,
              UInt64(initialPathStatus.st_size) <= maximumLiveStubBytes else {
            throw POSIXError(.EFBIG)
        }
        let inputDescriptor = open(
            stubURL.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard inputDescriptor >= 0 else { throw POSIXError(.EIO) }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var initialDescriptorStatus = stat()
        guard fstat(inputDescriptor, &initialDescriptorStatus) == 0,
              stableFileStatus(initialDescriptorStatus, matches: initialPathStatus) else {
            throw POSIXError(.EIO)
        }

        var initialRestorePathStatus = stat()
        guard lstat(restoreURL.path, &initialRestorePathStatus) == 0,
              initialRestorePathStatus.st_mode & S_IFMT == S_IFREG,
              initialRestorePathStatus.st_uid == geteuid(),
              initialRestorePathStatus.st_nlink == 1 else {
            throw POSIXError(.EIO)
        }
        let outputDescriptor = open(
            restoreURL.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard outputDescriptor >= 0 else { throw POSIXError(.EIO) }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var initialRestoreDescriptorStatus = stat()
        guard fstat(outputDescriptor, &initialRestoreDescriptorStatus) == 0,
              stableFileStatus(
                initialRestoreDescriptorStatus,
                matches: initialRestorePathStatus
              ),
              initialRestoreDescriptorStatus.st_uid == geteuid(),
              initialRestoreDescriptorStatus.st_nlink == 1 else {
            throw POSIXError(.EIO)
        }
        let endOffset = try output.seekToEnd()
        let trimmedOffset = try offsetByTrimmingTrailingNewlines(handle: output, endOffset: endOffset)
        try output.truncate(atOffset: trimmedOffset)
        try output.seekToEnd()
        try output.write(contentsOf: Data([10]))

        var skippingLeadingNewlines = true
        var remainingBytes = UInt64(initialDescriptorStatus.st_size)
        while remainingBytes > 0 {
            let chunk = try input.read(
                upToCount: Int(min(UInt64(64 * 1_024), remainingBytes))
            ) ?? Data()
            guard !chunk.isEmpty else { throw POSIXError(.EIO) }
            remainingBytes -= UInt64(chunk.count)
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
        try output.synchronize()
        var finalDescriptorStatus = stat()
        var finalPathStatus = stat()
        var finalRestoreDescriptorStatus = stat()
        var finalRestorePathStatus = stat()
        guard fstat(inputDescriptor, &finalDescriptorStatus) == 0,
              lstat(stubURL.path, &finalPathStatus) == 0,
              stableFileStatus(finalDescriptorStatus, matches: initialDescriptorStatus),
              stableFileStatus(finalPathStatus, matches: initialDescriptorStatus),
              fstat(outputDescriptor, &finalRestoreDescriptorStatus) == 0,
              lstat(restoreURL.path, &finalRestorePathStatus) == 0,
              sameRegularFileIdentity(
                finalRestoreDescriptorStatus,
                initialRestoreDescriptorStatus
              ),
              sameRegularFileIdentity(
                finalRestorePathStatus,
                initialRestoreDescriptorStatus
              ),
              finalRestoreDescriptorStatus.st_uid == geteuid(),
              finalRestoreDescriptorStatus.st_nlink == 1,
              finalRestorePathStatus.st_uid == geteuid(),
              finalRestorePathStatus.st_nlink == 1 else {
            throw POSIXError(.EIO)
        }
    }

    private static func sameRegularFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFREG
            && rhs.st_mode & S_IFMT == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func stableFileStatus(_ lhs: stat, matches rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFREG
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
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
