import Darwin
import Foundation

struct SudoSpoolStore {
    enum ApprovalTransition {
        case approved(SudoExecutionManifest)
        case expired
        case unavailable
    }

    let paths: SudoBrokerPaths
    private let fileManager: FileManager
    private let maximumRequestBytes = 64 * 1_024
    private let maximumScriptBytes = 16 * 1_024 * 1_024

    init(paths: SudoBrokerPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
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
    }

    func enqueue(_ pending: SudoPendingRequest) throws {
        guard Self.isValidRequestID(pending.request.id) else {
            throw SudoSpoolError.invalidRequestID
        }
        try ensureDirectories()
        let id = pending.request.id
        let scriptURL = paths.requests.appendingPathComponent("\(id).sh")
        let requestURL = paths.requests.appendingPathComponent("\(id).json")
        guard try writeAtomically(
            Data(pending.script.utf8),
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
                try Self.encoder.encode(pending.request),
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

    func pendingRequests() -> [SudoPendingRequest] {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.requests.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard Self.isValidRequestID(id),
                  result(id: id) == nil,
                  let requestData = try? readData(
                    at: paths.requests.appendingPathComponent(name),
                    maximumBytes: maximumRequestBytes
                  ),
                  let request = try? Self.decoder.decode(SudoRequest.self, from: requestData),
                  request.id == id,
                  let scriptData = try? readData(
                    at: paths.requests.appendingPathComponent("\(id).sh"),
                    maximumBytes: maximumScriptBytes
                  ),
                  let script = String(data: scriptData, encoding: .utf8) else {
                return nil
            }
            let phase = state(id: id)?.phase ?? .pendingApproval
            return SudoPendingRequest(request: request, script: script, phase: phase)
        }
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
        guard Self.isValidRequestID(id),
              let data = try? readData(
                at: paths.results.appendingPathComponent("\(id).json"),
                maximumBytes: maximumRequestBytes
              ) else {
            return nil
        }
        guard let result = try? Self.decoder.decode(SudoResult.self, from: data),
              result.id == id else {
            return nil
        }
        return result
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
            let approvedURL = paths.approved.appendingPathComponent("\(id).sh")
            let manifestURL = paths.executions.appendingPathComponent("\(id).json")
            guard try writeAtomically(
                Data(pending.script.utf8),
                to: approvedURL,
                permissions: 0o600,
                exclusive: true
            ) else {
                throw SudoSpoolError.approvedScriptAlreadyExists
            }
            let manifest = SudoExecutionManifest(
                id: id,
                currentDirectory: pending.request.currentDirectory,
                deadline: pending.request.approvalDeadline.addingTimeInterval(executionGraceSeconds)
            )
            do {
                guard try writeAtomically(
                    try Self.encoder.encode(manifest),
                    to: manifestURL,
                    permissions: 0o600,
                    exclusive: true
                ) else {
                    throw SudoSpoolError.executionAlreadyExists
                }
                try writeState(
                    SudoRequestState(id: id, phase: .approved, updatedAt: now)
                )
                return .approved(manifest)
            } catch {
                try? fileManager.removeItem(at: approvedURL)
                try? fileManager.removeItem(at: manifestURL)
                throw error
            }
        }
    }

    func claimApprovedExecution(id: String, runner: SudoProcessIdentity, now: Date) throws -> SudoExecutionManifest? {
        try withRequestLock(id: id) {
            guard result(id: id) == nil,
                  state(id: id)?.phase == .approved,
                  let manifest = manifest(id: id),
                  manifest.id == id else {
                return nil
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
            guard let authoritativeResult = self.result(id: result.id) else {
                throw SudoSpoolError.invalidExistingResult
            }
            archiveArtifacts(
                id: result.id,
                preserveExecutionEvidence: authoritativeResult.errorCode == .processCleanupFailed
            )
            return didWrite
        }
    }

    func settlePendingTimeout(_ result: SudoResult) throws -> SudoCLITimeoutDisposition {
        try withRequestLock(id: result.id) {
            let phase = state(id: result.id)?.phase
            let disposition = SudoCLITimeoutDisposition.resolve(phase: phase)
            guard disposition == .pendingApproval, self.result(id: result.id) == nil else {
                return disposition
            }
            _ = try writeResultIfAbsent(result)
            guard self.result(id: result.id) != nil else {
                throw SudoSpoolError.invalidExistingResult
            }
            archiveArtifacts(id: result.id, preserveExecutionEvidence: false)
            return .pendingApproval
        }
    }

    func cleanupFailureStates() -> [SudoRequestState] {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.states.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            let id = String(name.dropLast(5))
            guard result(id: id)?.errorCode == .processCleanupFailed else { return nil }
            return state(id: id)
        }
    }

    func archiveRecoveredCleanup(id: String) throws {
        try withRequestLock(id: id) {
            guard result(id: id)?.errorCode == .processCleanupFailed else { return }
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
                (
                    paths.approved.appendingPathComponent("\(id).sh"),
                    paths.archive.appendingPathComponent("\(id).approved.sh")
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
    }

    func appendAudit(_ line: String) {
        let sanitized = line.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let descriptor = Darwin.open(
            paths.auditLog.path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        let data = Data((sanitized + "\n").utf8)
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
        let lockURL = paths.locks.appendingPathComponent("\(id).lock")
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

private enum SudoSpoolError: Error {
    case invalidRequestID
    case requestAlreadyExists
    case approvedScriptAlreadyExists
    case executionAlreadyExists
    case unsafeDirectory(String)
    case invalidFile(String)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)
    case lockFailed(Int32)
    case invalidExistingResult
}
