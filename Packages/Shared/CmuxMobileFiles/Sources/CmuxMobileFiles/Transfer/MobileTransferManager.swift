import CmuxMobileLink
import CmuxMobileWire
import Foundation

/// Runs transfers against Macs and keeps the journal (c4-files.md sections 4
/// and 5). One task per transfer; progress streams per run. A digest
/// mismatch restarts once from zero; a lost session leaves the transfer
/// resumable; `pauseAll` (backgrounding) stops every run as `paused`.
public actor MobileTransferManager {
    /// Host id -> the phone's one `MobileLinkClient` for that Mac (it makes
    /// a new link session per generation, so a lost session resumes on the
    /// same client).
    public typealias Connector = @Sendable (String) async throws -> MobileLinkClient

    private let connector: Connector
    private let journal: TransferJournal
    private let chunkBytes: Int
    /// Live runs by transfer id; the token tells a run from its replacement.
    private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var cancelled: Set<UUID> = []
    /// The latest byte count per running transfer, so the journal shows where a run stopped.
    private var latest: [String: UInt64] = [:]

    public init(connector: @escaping Connector, journal: TransferJournal, chunkBytes: Int = MobileFileClient.defaultChunkBytes) {
        self.connector = connector
        self.journal = journal
        self.chunkBytes = chunkBytes
    }

    public func records() async -> [TransferRecord] {
        await journal.all()
    }

    public func start(_ request: MobileTransferRequest) async -> AsyncStream<MobileTransferUpdate> {
        let record = TransferRecord(id: request.id, hostID: request.hostID, direction: request.direction,
                                    localPath: request.localURL.path, remotePath: request.remotePath, name: request.name,
                                    mime: request.mime, dest: request.dest)
        await journal.put(record)
        return await run(record.id)
    }

    /// Resumes a paused or failed transfer from its journal record.
    public func resume(_ id: String) async throws -> AsyncStream<MobileTransferUpdate> {
        guard let record = await journal.record(id) else {
            throw MobileClientError(code: "files.not_found", message: "no such transfer")
        }
        guard record.status != .finished, record.status != .cancelled else {
            throw MobileClientError(code: "validation.invalid", message: "the transfer already ended")
        }
        return await run(id)
    }

    /// Cancels at once: the channel closes, a download's part is deleted.
    public func cancel(_ id: String) async {
        if let run = tasks[id] {
            cancelled.insert(run.token)
            run.task.cancel()
            return
        }
        guard let record = await journal.record(id), record.status != .finished, record.status != .cancelled else { return }
        await markCancelled(record)
    }

    /// Stops every running transfer as `paused` (the app is being suspended).
    public func pauseAll() {
        for run in tasks.values { run.task.cancel() }
    }

    /// Whether any transfer runs (background task bookkeeping).
    public var isRunning: Bool { !tasks.isEmpty }

    // MARK: Run

    /// Stops a previous run of `id` and waits for it, so two runs never
    /// write the same part file or journal record.
    private func run(_ id: String) async -> AsyncStream<MobileTransferUpdate> {
        while let old = tasks[id] {
            old.task.cancel()
            await old.task.value
        }
        let (stream, continuation) = AsyncStream.makeStream(of: MobileTransferUpdate.self, bufferingPolicy: .bufferingNewest(32))
        let token = UUID()
        tasks[id] = (token, Task { await self.execute(id, token: token, continuation) })
        return stream
    }

    private func execute(_ id: String, token: UUID, _ continuation: AsyncStream<MobileTransferUpdate>.Continuation) async {
        defer {
            continuation.finish()
            if tasks[id]?.token == token { tasks[id] = nil }
            cancelled.remove(token)
        }
        guard var record = await journal.update(id, { $0.status = .running }) else { return }
        continuation.yield(update(record))
        var restarted = false
        while true {
            do {
                record = try await transfer(record, continuation)
                continuation.yield(update(record))
                return
            } catch {
                if Task.isCancelled {
                    if cancelled.contains(token) {
                        record = await markCancelled(record)
                    } else {
                        let completed = latest.removeValue(forKey: id) ?? record.completedBytes
                        record = await journal.update(id) {
                            $0.status = .paused
                            $0.completedBytes = completed
                        } ?? record
                    }
                    continuation.yield(update(record))
                    return
                }
                let failure = error as? MobileClientError
                    ?? MobileClientError(code: "owner.unreachable", message: "\(error)", retryable: true)
                if failure.code == "files.digest_mismatch", !restarted {
                    restarted = true
                    record = await journal.update(id) { $0.sha256 = $0.direction == .download ? nil : $0.sha256 } ?? record
                    continue
                }
                let completed = latest.removeValue(forKey: id) ?? record.completedBytes
                record = await journal.update(id) {
                    $0.status = .failed(code: failure.code, message: failure.message, retryable: failure.retryable)
                    $0.completedBytes = completed
                } ?? record
                continuation.yield(update(record))
                return
            }
        }
    }

    private func transfer(_ record: TransferRecord, _ continuation: AsyncStream<MobileTransferUpdate>.Continuation)
        async throws -> TransferRecord {
        let session = try await connector(record.hostID)
        try Task.checkCancellation()
        let client = MobileFileClient(session: session, chunkBytes: chunkBytes)
        let id = record.id
        let progress: @Sendable (UInt64, UInt64) async -> Void = { [weak self] completed, total in
            await self?.recordProgress(id, completed)
            continuation.yield(MobileTransferUpdate(id: id, completedBytes: completed, totalBytes: total, status: .running))
        }
        switch record.direction {
        case .upload:
            let source = URL(fileURLWithPath: record.localPath)
            var sha = record.sha256
            if sha == nil {
                // Hash off the actor so cancel and pauseAll stay responsive.
                let digest = try await Task.detached { try LocalFileDigest(url: source).sha256() }.value
                try Task.checkCancellation()
                let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.uint64Value
                await journal.update(id) {
                    $0.sha256 = digest
                    $0.size = size
                }
                sha = digest
            }
            let done = try await client.upload(source, name: record.name, mime: record.mime, sha256: sha ?? "",
                                               dest: record.dest ?? FilesUploadDestination(kind: .composer), progress: progress)
            latest[id] = nil
            return await journal.update(id) {
                $0.status = .finished
                $0.resultPath = done.path
                $0.uploadID = done.upload
                $0.completedBytes = done.size
                $0.size = done.size
            } ?? record
        case .download:
            let journal = journal
            let part = URL(fileURLWithPath: record.partPath)
            let info = try await client.download(record.remotePath, into: part, expectedSHA256: record.sha256, opened: { info in
                await journal.update(id) {
                    $0.sha256 = info.sha256
                    $0.size = info.size
                    $0.mime = info.mime
                }
            }, progress: progress)
            latest[id] = nil
            let final = URL(fileURLWithPath: record.localPath)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: part, to: final)
            return await journal.update(id) {
                $0.status = .finished
                $0.completedBytes = info.size
                $0.size = info.size
                $0.sha256 = info.sha256
                $0.mime = info.mime
            } ?? record
        }
    }

    private func recordProgress(_ id: String, _ completed: UInt64) {
        latest[id] = completed
    }

    @discardableResult
    private func markCancelled(_ record: TransferRecord) async -> TransferRecord {
        if record.direction == .download {
            try? FileManager.default.removeItem(atPath: record.partPath)
        }
        return await journal.update(record.id) { $0.status = .cancelled } ?? record
    }

    private func update(_ record: TransferRecord) -> MobileTransferUpdate {
        MobileTransferUpdate(id: record.id, completedBytes: record.completedBytes, totalBytes: record.size,
                             status: record.status, resultPath: record.resultPath, uploadID: record.uploadID)
    }
}
