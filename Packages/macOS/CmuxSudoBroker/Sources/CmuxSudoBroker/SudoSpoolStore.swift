import CryptoKit
import Darwin
import Foundation

struct SudoSpoolStore {
    enum ApprovalTransition {
        case approved(SudoExecutionManifest)
        case expired
        case unavailable
    }

    let paths: SudoBrokerPaths
    let resourcePolicy: SudoResourcePolicy
    private let fileManager: FileManager
    private let now: () -> Date
    private let maximumRequestBytes = 64 * 1_024
    private static let commitmentByteCount = 32

    init(
        paths: SudoBrokerPaths,
        resourcePolicy: SudoResourcePolicy = .standard,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { .now }
    ) {
        self.paths = paths
        self.resourcePolicy = resourcePolicy
        self.fileManager = fileManager
        self.now = now
    }

    func ensureDirectories() throws {
        for directory in [
            paths.base, paths.requests, paths.results, paths.states,
            paths.executions, paths.approved, paths.archive, paths.locks,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var status = stat()
            guard lstat(directory.path, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR,
                  status.st_uid == geteuid() else {
                throw SudoSpoolError.unsafeDirectory(directory.path)
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        reconcileResultCommitments()
        performMaintenance(at: now())
    }

    func enqueue(_ pending: SudoPendingRequest) throws {
        guard Self.isValidRequestID(pending.request.id) else {
            throw SudoSpoolError.invalidRequestID
        }
        try ensureDirectories()
        let scriptData = Data(pending.script.utf8)
        guard scriptData.count <= resourcePolicy.maximumScriptBytes else {
            throw SudoSpoolError.scriptTooLarge
        }
        let requestData = try Self.encoder.encode(pending.request)
        guard requestData.count <= maximumRequestBytes else {
            throw SudoSpoolError.requestMetadataTooLarge
        }
        try withStoreLock(name: "admission") {
            let usage = pendingUsage(at: now())
            guard usage.requestCount < resourcePolicy.maximumPendingRequestCount,
                  usage.scriptBytes + scriptData.count
                    <= resourcePolicy.maximumPendingScriptBytes else {
                throw SudoSpoolError.requestCapacityExceeded
            }

            let id = pending.request.id
            let scriptURL = paths.requests.appendingPathComponent("\(id).sh")
            let requestURL = paths.requests.appendingPathComponent("\(id).json")
            guard try writeAtomically(
                scriptData,
                to: scriptURL,
                permissions: 0o600,
                exclusive: true
            ) else {
                throw SudoSpoolError.requestAlreadyExists
            }
            do {
                try writeState(
                    SudoRequestState(
                        id: id,
                        phase: .pendingApproval,
                        updatedAt: pending.request.createdAt
                    )
                )
                guard try writeAtomically(
                    requestData,
                    to: requestURL,
                    permissions: 0o600,
                    exclusive: true
                ) else {
                    throw SudoSpoolError.requestAlreadyExists
                }
            } catch {
                try? fileManager.removeItem(at: scriptURL)
                try? fileManager.removeItem(at: stateURL(id: id))
                throw error
            }
        }
    }

    /// Reads at most the configured pending and active request envelope.
    ///
    /// Files beyond the envelope are rejected from discovery and remain inert;
    /// normal maintenance reclaims stale artifacts.
    func pendingRequests() -> [SudoPendingRequest] {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.requests.path)) ?? []
        var pendingCount = 0
        var pendingScriptBytes = 0
        var activeCount = 0
        var snapshots: [SudoPendingRequest] = []
        for name in names.sorted() {
            guard name.hasSuffix(".json") else { continue }
            let id = String(name.dropLast(5))
            guard Self.isValidRequestID(id),
                  authoritativeResult(id: id) == nil,
                  let requestData = try? readData(
                    at: paths.requests.appendingPathComponent(name),
                    maximumBytes: maximumRequestBytes
                  ),
                  let request = try? Self.decoder.decode(SudoRequest.self, from: requestData),
                  request.id == id,
                  let scriptData = try? readData(
                    at: paths.requests.appendingPathComponent("\(id).sh"),
                    maximumBytes: resourcePolicy.maximumScriptBytes
                  ),
                  let script = String(data: scriptData, encoding: .utf8) else {
                continue
            }
            let phase = state(id: id)?.phase ?? .pendingApproval
            switch phase {
            case .pendingApproval:
                let maximumCount = max(0, resourcePolicy.maximumPendingRequestCount)
                let maximumBytes = max(0, resourcePolicy.maximumPendingScriptBytes)
                guard pendingCount < maximumCount,
                      scriptData.count <= maximumBytes - pendingScriptBytes else {
                    continue
                }
                pendingCount += 1
                pendingScriptBytes += scriptData.count
            case .approved, .executing:
                guard activeCount < resourcePolicy.maximumActiveRunnerCount else {
                    continue
                }
                activeCount += 1
            }
            snapshots.append(
                SudoPendingRequest(request: request, script: script, phase: phase)
            )
        }
        return snapshots
    }

    func state(id: String) -> SudoRequestState? {
        guard Self.isValidRequestID(id),
              let data = try? readData(at: stateURL(id: id), maximumBytes: maximumRequestBytes) else {
            return nil
        }
        guard let state = try? Self.decoder.decode(SudoRequestState.self, from: data),
              state.id == id else {
            return nil
        }
        return state
    }

    func writeState(_ state: SudoRequestState) throws {
        guard Self.isValidRequestID(state.id) else { throw SudoSpoolError.invalidRequestID }
        _ = try writeAtomically(
            try Self.encoder.encode(state),
            to: stateURL(id: state.id),
            permissions: 0o600,
            exclusive: false
        )
    }

    func result(id: String) -> SudoResult? {
        guard let data = resultData(id: id) else { return nil }
        guard let result = try? Self.decoder.decode(SudoResult.self, from: data),
              result.id == id else {
            return nil
        }
        return result
    }

    /// Returns a result only after the request artifacts have been durably settled.
    ///
    /// A result file that appears while request/state artifacts are still live is
    /// treated as an untrusted preexisting write and never drives broker or CLI
    /// state transitions.
    func authoritativeResult(id: String) -> SudoResult? {
        guard let data = resultData(id: id),
              let result = try? Self.decoder.decode(SudoResult.self, from: data),
              result.id == id,
              let commitment = try? readData(
                  at: resultCommitmentURL(id: id),
                  maximumBytes: Self.commitmentByteCount
              ),
              commitment == Self.resultCommitment(for: data) else {
            return nil
        }
        guard !hasLiveSettlementEvidence(id: id, result: result) else { return nil }
        return result
    }

    private func resultData(id: String) -> Data? {
        guard Self.isValidRequestID(id) else { return nil }
        return try? readData(
            at: paths.results.appendingPathComponent("\(id).json"),
            maximumBytes: maximumRequestBytes
        )
    }

    private func resultCommitmentURL(id: String) -> URL {
        paths.results.appendingPathComponent("\(id).commit")
    }

    private static func resultCommitment(for data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    func manifest(id: String) -> SudoExecutionManifest? {
        guard Self.isValidRequestID(id),
              let data = try? readData(
                at: paths.executions.appendingPathComponent("\(id).json"),
                maximumBytes: maximumRequestBytes
              ) else {
            return nil
        }
        guard let manifest = try? Self.decoder.decode(SudoExecutionManifest.self, from: data),
              manifest.id == id else {
            return nil
        }
        return manifest
    }

    func transitionToApproved(
        pending: SudoPendingRequest,
        now: Date,
        executionGraceSeconds: TimeInterval
    ) throws -> ApprovalTransition {
        try withRequestLock(id: pending.request.id) {
            let id = pending.request.id
            guard result(id: id) == nil,
                  state(id: id)?.phase == .pendingApproval else {
                return .unavailable
            }
            guard pending.request.approvalDeadline > now else {
                return .expired
            }
            guard let requesterIdentity = pending.request.requesterIdentity else {
                return .unavailable
            }
            let approvedURL = paths.approved.appendingPathComponent("\(id).sh")
            let manifestURL = paths.executions.appendingPathComponent("\(id).json")
            let manifest = SudoExecutionManifest(
                id: id,
                requesterIdentity: requesterIdentity,
                currentDirectory: pending.request.currentDirectory,
                directoryIdentity: try SudoDirectoryIdentity(
                    path: pending.request.currentDirectory
                ),
                deadline: pending.request.approvalDeadline.addingTimeInterval(executionGraceSeconds)
            )
            let scriptData = Data(pending.script.utf8)
            let existingApprovedData = try? readData(
                at: approvedURL,
                maximumBytes: resourcePolicy.maximumScriptBytes
            )
            let artifactsMatch = existingApprovedData == scriptData
                && self.manifest(id: id) == manifest
            var createdArtifacts = false
            if !artifactsMatch {
                if fileManager.fileExists(atPath: approvedURL.path)
                    || fileManager.fileExists(atPath: manifestURL.path) {
                    try? fileManager.removeItem(at: approvedURL)
                    try? fileManager.removeItem(at: manifestURL)
                }
                guard try writeAtomically(
                    scriptData,
                    to: approvedURL,
                    permissions: 0o600,
                    exclusive: true
                ) else {
                    throw SudoSpoolError.approvedScriptAlreadyExists
                }
                do {
                    guard try writeAtomically(
                        try Self.encoder.encode(manifest),
                        to: manifestURL,
                        permissions: 0o600,
                        exclusive: true
                    ) else {
                        throw SudoSpoolError.executionAlreadyExists
                    }
                    createdArtifacts = true
                } catch {
                    try? fileManager.removeItem(at: approvedURL)
                    try? fileManager.removeItem(at: manifestURL)
                    throw error
                }
            }
            do {
                try writeState(
                    SudoRequestState(id: id, phase: .approved, updatedAt: now)
                )
                return .approved(manifest)
            } catch {
                if createdArtifacts {
                    try? fileManager.removeItem(at: approvedURL)
                    try? fileManager.removeItem(at: manifestURL)
                }
                throw error
            }
        }
    }

    func claimApprovedExecution(
        id: String,
        runner: SudoProcessIdentity,
        now: Date,
        expectedManifest: SudoExecutionManifest? = nil
    ) throws -> SudoExecutionManifest? {
        try withRequestLock(id: id) {
            guard result(id: id) == nil,
                  state(id: id)?.phase == .approved,
                  let manifest = manifest(id: id),
                  manifest.id == id else {
                return nil
            }
            if let expectedManifest, manifest != expectedManifest {
                throw SudoSpoolError.manifestMismatch
            }
            try writeState(
                SudoRequestState(
                    id: id,
                    phase: .executing,
                    updatedAt: now,
                    runner: runner
                )
            )
            return manifest
        }
    }

    func recordExecutionIdentity(id: String, execution: SudoProcessIdentity, now: Date) throws -> Bool {
        try withRequestLock(id: id) {
            guard let current = state(id: id),
                  current.phase == .executing,
                  result(id: id) == nil else {
                return false
            }
            try writeState(
                SudoRequestState(
                    id: id,
                    phase: .executing,
                    updatedAt: now,
                    runner: current.runner,
                    execution: execution
                )
            )
            return true
        }
    }

    func recordCleanupSurvivors(
        id: String,
        survivors: [SudoProcessIdentity],
        now: Date
    ) throws -> Bool {
        try withRequestLock(id: id) {
            guard let current = state(id: id),
                  current.phase == .executing,
                  result(id: id) == nil else {
                return false
            }
            let uniqueSurvivors = Set(survivors).sorted {
                ($0.processIdentifier, $0.startSeconds, $0.startMicroseconds)
                    < ($1.processIdentifier, $1.startSeconds, $1.startMicroseconds)
            }
            try writeState(
                SudoRequestState(
                    id: id,
                    phase: .executing,
                    updatedAt: now,
                    runner: current.runner,
                    execution: current.execution,
                    cleanupSurvivors: uniqueSurvivors
                )
            )
            return true
        }
    }

    @discardableResult
    func settle(_ result: SudoResult) throws -> Bool {
        try withRequestLock(id: result.id) {
            let didWrite = try writeResultIfAbsent(result)
            guard let persistedResult = self.result(id: result.id) else {
                throw SudoSpoolError.invalidExistingResult
            }
            guard persistedResult == result else {
                guard self.authoritativeResult(id: result.id) != nil else {
                    throw SudoSpoolError.resultAlreadyExists
                }
                return false
            }
            guard let persistedData = resultData(id: result.id) else {
                throw SudoSpoolError.invalidExistingResult
            }
            // Publish the commitment before moving the request artifacts. The
            // authoritative read still requires those artifacts to be gone, so
            // a crash after this write can be reconciled safely on startup.
            try writeResultCommitmentIfNeeded(id: result.id, data: persistedData)
            archiveArtifacts(
                id: result.id,
                preserveExecutionEvidence: persistedResult.errorCode == .processCleanupFailed
            )
            guard !hasLiveSettlementEvidence(id: result.id, result: persistedResult),
                  resultData(id: result.id) != nil else {
                throw SudoSpoolError.settlementIncomplete
            }
            return didWrite
        }
    }

    func settlePendingTimeout(_ result: SudoResult) throws -> SudoCLITimeoutDisposition {
        try withRequestLock(id: result.id) {
            let phase = state(id: result.id)?.phase
            let disposition = SudoCLITimeoutDisposition.resolve(phase: phase)
            guard disposition == .pendingApproval else {
                return disposition
            }
            let persistedResult: SudoResult
            if let existingResult = self.result(id: result.id) {
                if self.authoritativeResult(id: result.id) != nil {
                    return disposition
                }
                guard existingResult == result else {
                    throw SudoSpoolError.resultAlreadyExists
                }
                persistedResult = existingResult
            } else {
                guard try writeResultIfAbsent(result) else {
                    guard let existingResult = self.result(id: result.id),
                          existingResult == result else {
                        throw SudoSpoolError.resultAlreadyExists
                    }
                    persistedResult = existingResult
                    return try commitPendingTimeout(
                        result: persistedResult,
                        disposition: disposition
                    )
                }
                persistedResult = result
            }
            return try commitPendingTimeout(
                result: persistedResult,
                disposition: disposition
            )
        }
    }

    private func commitPendingTimeout(
        result: SudoResult,
        disposition: SudoCLITimeoutDisposition
    ) throws -> SudoCLITimeoutDisposition {
        guard let persistedData = resultData(id: result.id),
              let persistedResult = self.result(id: result.id),
              persistedResult == result else {
            throw SudoSpoolError.invalidExistingResult
        }
        // Keep the commitment durable before archival so a killed CLI can be
        // repaired by the next spool startup.
        try writeResultCommitmentIfNeeded(id: result.id, data: persistedData)
        archiveArtifacts(id: result.id, preserveExecutionEvidence: false)
        guard !hasLiveSettlementEvidence(id: result.id, result: persistedResult) else {
            throw SudoSpoolError.settlementIncomplete
        }
        return disposition
    }

    private func writeResultCommitmentIfNeeded(id: String, data: Data) throws {
        let expected = Self.resultCommitment(for: data)
        let url = resultCommitmentURL(id: id)
        if fileManager.fileExists(atPath: url.path) {
            guard let existing = try? readData(
                at: url,
                maximumBytes: Self.commitmentByteCount
            ), existing == expected else {
                throw SudoSpoolError.resultAlreadyExists
            }
            return
        }
        guard try writeAtomically(
            expected,
            to: url,
            permissions: 0o600,
            exclusive: true
        ) else {
            guard let existing = try? readData(
                at: url,
                maximumBytes: Self.commitmentByteCount
            ), existing == expected else {
                throw SudoSpoolError.settlementIncomplete
            }
            return
        }
    }

    func cleanupFailureStates() -> [SudoRequestState] {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.states.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard authoritativeResult(id: id)?.errorCode == .processCleanupFailed else { return nil }
            return state(id: id)
        }
    }

    func archiveRecoveredCleanup(id: String) throws {
        try withRequestLock(id: id) {
            guard authoritativeResult(id: id)?.errorCode == .processCleanupFailed else { return }
            archiveArtifacts(id: id, preserveExecutionEvidence: false)
        }
    }

    @discardableResult
    func writeResultIfAbsent(_ result: SudoResult) throws -> Bool {
        guard Self.isValidRequestID(result.id) else { throw SudoSpoolError.invalidRequestID }
        return try writeAtomically(
            try Self.encoder.encode(result),
            to: paths.results.appendingPathComponent("\(result.id).json"),
            permissions: 0o600,
            exclusive: true
        )
    }

    func outputURL(id: String) -> URL {
        paths.results.appendingPathComponent("\(id).out")
    }

    func acquireResultLease(id: String) throws -> Int32 {
        // Cross-process lease: the CLI waiter and app broker are independent processes.
        guard Self.isValidRequestID(id) else { throw SudoSpoolError.invalidRequestID }
        let url = paths.locks.appendingPathComponent("\(id).result-lease.lock")
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw SudoSpoolError.lockFailed(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            Darwin.close(descriptor)
            throw SudoSpoolError.lockFailed(error)
        }
        return descriptor
    }

    func releaseResultLease(id: String, descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        if Self.isValidRequestID(id) {
            _ = unlink(paths.locks.appendingPathComponent("\(id).result-lease.lock").path)
        }
    }

    func removeOutput(id: String) {
        guard Self.isValidRequestID(id) else { return }
        _ = unlink(outputURL(id: id).path)
    }

    func requeueAfterSettlementFailure(id: String, now: Date) throws -> Bool {
        try withRequestLock(id: id) {
            guard state(id: id)?.phase == .approved, result(id: id) == nil else {
                return false
            }
            try? fileManager.removeItem(at: approvedScriptURL(id: id))
            try? fileManager.removeItem(
                at: paths.executions.appendingPathComponent("\(id).json")
            )
            try writeState(SudoRequestState(id: id, phase: .pendingApproval, updatedAt: now))
            return true
        }
    }

    func approvedScriptURL(id: String) -> URL {
        paths.approved.appendingPathComponent("\(id).sh")
    }

    func archiveArtifacts(id: String, preserveExecutionEvidence: Bool) {
        guard Self.isValidRequestID(id) else { return }
        var files: [(URL, URL)] = [
            (
                paths.requests.appendingPathComponent("\(id).json"),
                paths.archive.appendingPathComponent("\(id).json")
            ),
            (
                paths.requests.appendingPathComponent("\(id).sh"),
                paths.archive.appendingPathComponent("\(id).sh")
            ),
        ]
        if !preserveExecutionEvidence {
            files.append(contentsOf: [
                (
                    stateURL(id: id),
                    paths.archive.appendingPathComponent("\(id).state.json")
                ),
                (
                    paths.executions.appendingPathComponent("\(id).json"),
                    paths.archive.appendingPathComponent("\(id).execution.json")
                ),
            ])
        }
        for (source, destination) in files {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: source)
            } else {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
        if !preserveExecutionEvidence {
            try? fileManager.removeItem(
                at: paths.approved.appendingPathComponent("\(id).sh")
            )
        }
    }

    func appendAudit(_ line: String) {
        let sanitized = line.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let maximumLineBytes = min(4 * 1_024, resourcePolicy.maximumAuditBytes)
        let lineBytes = Data(sanitized.utf8).prefix(maximumLineBytes)
        let data = Data(lineBytes) + Data("\n".utf8)
        try? withStoreLock(name: "audit") {
            trimAuditLog(forIncomingByteCount: data.count)
            appendAuditData(data)
        }
    }

    private func appendAuditData(_ data: Data) {
        let descriptor = Darwin.open(
            paths.auditLog.path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func stateURL(id: String) -> URL {
        paths.states.appendingPathComponent("\(id).json")
    }

    private func performMaintenance(at date: Date) {
        let cutoff = date.addingTimeInterval(-resourcePolicy.artifactRetentionSeconds)
        pruneAtomicWriteTemps(before: cutoff)
        pruneOrphanedRequestArtifacts(before: cutoff)
        pruneRegularFiles(
            in: paths.archive,
            before: cutoff,
            maximumTotalBytes: resourcePolicy.maximumArchiveBytes,
            isEligible: { _ in true }
        )
        pruneRegularFiles(
            in: paths.results,
            before: cutoff,
            maximumTotalBytes: resourcePolicy.maximumOutputBytes,
            isEligible: { url in
                guard url.pathExtension == "out" else { return false }
                let id = url.deletingPathExtension().lastPathComponent
                return Self.isValidRequestID(id) && !hasActiveEvidence(id: id)
            }
        )
        pruneRegularFiles(
            in: paths.results,
            before: cutoff,
            maximumTotalBytes: resourcePolicy.maximumResultBytes,
            isEligible: { url in
                guard url.pathExtension == "json" else { return false }
                let id = url.deletingPathExtension().lastPathComponent
                return Self.isValidRequestID(id) && !hasActiveEvidence(id: id)
            }
        )
        pruneRegularFiles(
            in: paths.results,
            before: cutoff,
            maximumTotalBytes: resourcePolicy.maximumResultBytes,
            isEligible: { url in
                guard url.pathExtension == "commit" else { return false }
                let id = url.deletingPathExtension().lastPathComponent
                return Self.isValidRequestID(id) && !hasActiveEvidence(id: id)
            }
        )
        pruneRegularFiles(
            in: paths.locks,
            before: cutoff,
            maximumTotalBytes: .max,
            isEligible: { url in
                let name = url.lastPathComponent
                if name.hasSuffix(".result-lease.lock") {
                    let id = String(name.dropLast(".result-lease.lock".count))
                    return Self.isValidRequestID(id) && !resultLeaseIsHeld(id: id)
                }
                guard url.pathExtension == "lock" else { return false }
                let id = url.deletingPathExtension().lastPathComponent
                guard id != "admission", id != "audit" else { return false }
                return Self.isValidRequestID(id) && !hasAnyEvidence(id: id)
            }
        )
        try? withStoreLock(name: "audit") {
            trimAuditLog(forIncomingByteCount: 0)
        }
    }

    private func reconcileResultCommitments() {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.results.path)) ?? []
        for name in names where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            try? withRequestLock(id: id) {
                guard let data = resultData(id: id),
                      let result = try? Self.decoder.decode(SudoResult.self, from: data),
                      result.id == id else {
                    return
                }
                let commitmentURL = resultCommitmentURL(id: id)
                if fileManager.fileExists(atPath: commitmentURL.path) {
                    // A committed result may have been interrupted during
                    // archival. Verify the digest before touching any live
                    // request artifacts, then finish the moves.
                    guard let commitment = try? readData(
                        at: commitmentURL,
                        maximumBytes: Self.commitmentByteCount
                    ), commitment == Self.resultCommitment(for: data) else {
                        return
                    }
                    archiveArtifacts(
                        id: id,
                        preserveExecutionEvidence: result.errorCode == .processCleanupFailed
                    )
                    return
                }

                // Without a commitment, only a result whose request envelope
                // has already disappeared is eligible for crash recovery. A
                // live envelope could still be an unrelated preexisting write.
                let requestJSON = paths.requests.appendingPathComponent("\(id).json")
                let requestScript = paths.requests.appendingPathComponent("\(id).sh")
                guard !fileManager.fileExists(atPath: requestJSON.path),
                      !fileManager.fileExists(atPath: requestScript.path) else {
                    return
                }
                if hasLiveSettlementEvidence(id: id, result: result) {
                    archiveArtifacts(
                        id: id,
                        preserveExecutionEvidence: result.errorCode == .processCleanupFailed
                    )
                }
                guard !hasLiveSettlementEvidence(id: id, result: result) else { return }
                try? writeResultCommitmentIfNeeded(id: id, data: data)
            }
        }
    }

    private func hasLiveSettlementEvidence(id: String, result: SudoResult) -> Bool {
        let requestJSON = paths.requests.appendingPathComponent("\(id).json")
        let requestScript = paths.requests.appendingPathComponent("\(id).sh")
        if fileManager.fileExists(atPath: requestJSON.path)
            || fileManager.fileExists(atPath: requestScript.path) {
            return true
        }
        guard result.errorCode != .processCleanupFailed else { return false }
        return fileManager.fileExists(atPath: stateURL(id: id).path)
            || fileManager.fileExists(
                atPath: paths.executions.appendingPathComponent("\(id).json").path
            )
            || fileManager.fileExists(atPath: approvedScriptURL(id: id).path)
    }

    private func pruneAtomicWriteTemps(before cutoff: Date) {
        let directories = [
            paths.requests,
            paths.results,
            paths.states,
            paths.executions,
            paths.approved,
            paths.archive,
            paths.locks,
        ]
        for directory in directories {
            pruneRegularFiles(
                in: directory,
                before: cutoff,
                maximumTotalBytes: .max,
                isEligible: { url in
                    let name = url.lastPathComponent
                    return name.hasPrefix(".") && name.contains(".tmp.")
                }
            )
        }
    }

    private func pendingUsage(at date: Date) -> (requestCount: Int, scriptBytes: Int) {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.requests.path)) ?? []
        let maximumPendingRequestCount = max(0, resourcePolicy.maximumPendingRequestCount)
        let maximumPendingScriptBytes = max(0, resourcePolicy.maximumPendingScriptBytes)
        var requestCount = 0
        var scriptBytes = 0
        for name in names where name.hasSuffix(".sh") {
            if requestCount >= maximumPendingRequestCount
                || scriptBytes >= maximumPendingScriptBytes {
                return (
                    maximumPendingRequestCount,
                    maximumPendingScriptBytes
                )
            }
            let id = String(name.dropLast(3))
            // A raw result is still an execution/settlement barrier, but it is
            // not enough to release admission capacity until its commitment is
            // authoritative. This keeps forged preexisting results from
            // bypassing the pending-resource envelope.
            guard Self.isValidRequestID(id), authoritativeResult(id: id) == nil else {
                continue
            }
            let requestURL = paths.requests.appendingPathComponent("\(id).json")
            guard let data = try? readData(at: requestURL, maximumBytes: maximumRequestBytes),
                  let request = try? Self.decoder.decode(SudoRequest.self, from: data) else {
                continue
            }
            if request.approvalDeadline <= date {
                continue
            }
            let scriptURL = paths.requests.appendingPathComponent(name)
            guard let info = regularFileInfo(at: scriptURL) else { continue }
            guard info.size <= maximumPendingScriptBytes - scriptBytes else {
                return (maximumPendingRequestCount, maximumPendingScriptBytes)
            }
            requestCount += 1
            scriptBytes += info.size
        }
        return (requestCount, scriptBytes)
    }

    private func pruneOrphanedRequestArtifacts(before cutoff: Date) {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.requests.path)) ?? []
        for name in names where name.hasSuffix(".sh") || name.hasSuffix(".json") {
            let id = name.hasSuffix(".sh")
                ? String(name.dropLast(3))
                : String(name.dropLast(5))
            guard Self.isValidRequestID(id) else { continue }
            let url = paths.requests.appendingPathComponent(name)
            let counterpartName = name.hasSuffix(".sh") ? "\(id).json" : "\(id).sh"
            let counterpartURL = paths.requests.appendingPathComponent(counterpartName)
            guard !fileManager.fileExists(atPath: counterpartURL.path),
                  let info = regularFileInfo(at: url),
                  info.modifiedAt <= cutoff else {
                continue
            }
            _ = unlink(url.path)
        }
    }

    private func hasActiveEvidence(id: String) -> Bool {
        resultLeaseIsHeld(id: id)
            || fileManager.fileExists(
                atPath: paths.requests.appendingPathComponent("\(id).json").path
            ) || fileManager.fileExists(atPath: stateURL(id: id).path)
            || fileManager.fileExists(
                atPath: paths.requests.appendingPathComponent("\(id).sh").path
            )
            || fileManager.fileExists(
                atPath: paths.executions.appendingPathComponent("\(id).json").path
            )
            || fileManager.fileExists(
                atPath: paths.approved.appendingPathComponent("\(id).sh").path
            )
    }

    private func resultLeaseIsHeld(id: String) -> Bool {
        guard Self.isValidRequestID(id) else { return false }
        let url = paths.locks.appendingPathComponent("\(id).result-lease.lock")
        let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        let status = flock(descriptor, LOCK_EX | LOCK_NB)
        if status == 0 {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            return false
        }
        let held = errno == EWOULDBLOCK || errno == EAGAIN
        Darwin.close(descriptor)
        return held
    }

    private func hasAnyEvidence(id: String) -> Bool {
        hasActiveEvidence(id: id)
            || fileManager.fileExists(
                atPath: paths.results.appendingPathComponent("\(id).json").path
            )
            || fileManager.fileExists(atPath: resultCommitmentURL(id: id).path)
    }

    private func pruneRegularFiles(
        in directory: URL,
        before cutoff: Date,
        maximumTotalBytes: Int,
        isEligible: (URL) -> Bool
    ) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var files = names.compactMap { name -> RetainedFile? in
            let url = directory.appendingPathComponent(name)
            guard isEligible(url), let info = regularFileInfo(at: url) else { return nil }
            return RetainedFile(url: url, size: info.size, modifiedAt: info.modifiedAt)
        }
        files.sort {
            ($0.modifiedAt, $0.url.lastPathComponent)
                < ($1.modifiedAt, $1.url.lastPathComponent)
        }
        var totalBytes = files.reduce(0) { $0 + $1.size }
        for file in files where file.modifiedAt <= cutoff || totalBytes > maximumTotalBytes {
            guard unlink(file.url.path) == 0 else { continue }
            totalBytes -= file.size
        }
    }

    private func regularFileInfo(at url: URL) -> (size: Int, modifiedAt: Date)? {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size >= 0,
              let size = Int(exactly: status.st_size) else {
            return nil
        }
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return (size, modifiedAt)
    }

    private func trimAuditLog(forIncomingByteCount incomingByteCount: Int) {
        let maximumBytes = resourcePolicy.maximumAuditBytes
        guard maximumBytes > 0 else {
            _ = unlink(paths.auditLog.path)
            return
        }
        let descriptor = Darwin.open(
            paths.auditLog.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size >= 0,
              let currentSize = Int(exactly: status.st_size) else {
            return
        }
        let targetBytes = max(0, maximumBytes - incomingByteCount)
        guard currentSize > targetBytes else { return }
        let retainedBytes = min(resourcePolicy.retainedAuditBytes, targetBytes)
        let start = max(0, status.st_size - off_t(retainedBytes))
        guard lseek(descriptor, start, SEEK_SET) >= 0 else { return }
        var tail = Data(count: Int(status.st_size - start))
        var offset = 0
        while offset < tail.count {
            let remainingCount = tail.count - offset
            let count = tail.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    remainingCount
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
        if start > 0, let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail.removeSubrange(...newline)
        }
        guard ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0 else {
            return
        }
        var writeOffset = 0
        while writeOffset < tail.count {
            let count = tail.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: writeOffset),
                    tail.count - writeOffset
                )
            }
            if count > 0 {
                writeOffset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    private func readData(at url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SudoSpoolError.readFailed(url.path, errno) }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw SudoSpoolError.invalidFile(url.path)
        }

        var data = Data(count: Int(status.st_size))
        var offset = 0
        while offset < data.count {
            let remainingCount = data.count - offset
            let count = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    remainingCount
                )
            }
            if count > 0 {
                offset += count
            } else if count == 0 {
                data.removeSubrange(offset...)
                break
            } else if errno != EINTR {
                throw SudoSpoolError.readFailed(url.path, errno)
            }
        }
        return data
    }

    private func writeAtomically(
        _ data: Data,
        to url: URL,
        permissions: mode_t,
        exclusive: Bool
    ) throws -> Bool {
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UUID().uuidString)")
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard descriptor >= 0 else {
            throw SudoSpoolError.writeFailed(temporaryURL.path, errno)
        }

        var didClose = false
        defer {
            if !didClose { Darwin.close(descriptor) }
            _ = unlink(temporaryURL.path)
        }

        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count == 0 {
                throw SudoSpoolError.writeFailed(temporaryURL.path, EIO)
            } else if count < 0, errno != EINTR {
                throw SudoSpoolError.writeFailed(temporaryURL.path, errno)
            }
        }
        guard fsync(descriptor) == 0 else {
            throw SudoSpoolError.writeFailed(temporaryURL.path, errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            didClose = true
            throw SudoSpoolError.writeFailed(temporaryURL.path, errno)
        }
        didClose = true

        if exclusive {
            if link(temporaryURL.path, url.path) == 0 {
                return true
            }
            if errno == EEXIST {
                return false
            }
            throw SudoSpoolError.writeFailed(url.path, errno)
        }

        guard rename(temporaryURL.path, url.path) == 0 else {
            throw SudoSpoolError.writeFailed(url.path, errno)
        }
        return true
    }

    private func withRequestLock<Value>(
        id: String,
        operation: () throws -> Value
    ) throws -> Value {
        guard Self.isValidRequestID(id) else { throw SudoSpoolError.invalidRequestID }
        return try withStoreLock(name: id, operation: operation)
    }

    private func withStoreLock<Value>(
        name: String,
        operation: () throws -> Value
    ) throws -> Value {
        guard Self.isValidRequestID(name) else { throw SudoSpoolError.invalidRequestID }
        let lockURL = paths.locks.appendingPathComponent("\(name).lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw SudoSpoolError.lockFailed(errno) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw SudoSpoolError.lockFailed(errno) }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private struct RetainedFile {
        let url: URL
        let size: Int
        let modifiedAt: Date
    }

    private static func isValidRequestID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum SudoSpoolError: Error {
    case invalidRequestID
    case requestAlreadyExists
    case requestCapacityExceeded
    case requestMetadataTooLarge
    case scriptTooLarge
    case approvedScriptAlreadyExists
    case executionAlreadyExists
    case manifestMismatch
    case unsafeDirectory(String)
    case invalidFile(String)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)
    case lockFailed(Int32)
    case invalidExistingResult
    case resultAlreadyExists
    case settlementIncomplete
}
