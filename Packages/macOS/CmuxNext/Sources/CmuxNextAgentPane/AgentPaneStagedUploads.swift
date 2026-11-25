import CmuxNextCompat
package import CmuxNextWakeups
package import Foundation

/// The staged uploads (`chat.upload.begin/chunk/finish/cancel`, ``AgentPaneUploadStageRequest``) of
/// one kind of remote chat, a Cloud machine's or an ssh peer's. Each stage is an owner-only file of
/// any size that chunks append to; there is no size limit on a file or a batch. A gesture's batch
/// (``AgentPaneUploadBatch``) stays authorized while any of its stages lives. A stage's one transfer
/// owns its file: expiry skips it, and cancel stops it first and removes the file only after it
/// returned. One deadline removes abandoned stages and batches, with no sleeping task per stage
/// (plans/cmux-next/idle-wakeups.md). `Target` is where a stage goes.
@MainActor
package final class AgentPaneStagedUploads<Target> {
    /// A stage's chunk: each write is this size at most, whatever the file's size.
    package nonisolated static var chunkBytes: Int { 512 * 1024 }
    /// How long a stage, or a batch with no live stage, waits for its next request.
    package nonisolated static var lifetime: TimeInterval { 10 * 60 }

    /// What a complete stage hands its transfer.
    package struct Staged {
        package let target: Target
        package let file: URL
        package let name: String
    }

    private struct Transfer {
        let cancel: @MainActor () -> Void
        let settled: @MainActor () async -> Void
    }

    private struct Stage {
        var staged: Staged
        /// Removed with the stage: the staged file, or a folder of its own that holds it.
        var removing: URL
        var size: Int
        var received = 0
        var expires: Date
        var batch: String?
        var transfer: Transfer?
        var cleanup: Task<Void, Never>?
        var idle: Bool { transfer == nil && cleanup == nil }
    }

    private struct Batch {
        var target: Target
        var authorization: AgentPaneUploadBatch
    }

    /// A stage whose transfer delivered it, kept for a cancel that comes after: the page may drop
    /// the file once the answer is on its way (its x in that moment).
    private struct Delivered {
        var target: Target
        var undo: @MainActor () async -> Void
        var expires: Date
    }

    private var stages: [String: Stage] = [:]
    private var batches: [String: Batch] = [:]
    private var delivered: [String: Delivered] = [:]
    private let expiry: DemandTimer

    /// `owner` names the expiry deadline in the wakeup ledger.
    package init(owner: String) {
        expiry = DemandTimer(owner: owner)
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050, #23233);
    // the DemandTimer cancels its own deadline when it goes.
    nonisolated deinit {}

    /// Whether a begin of `name`, `size` bytes, that starts the batch `manifest` (nil for a lone file
    /// or a later file of a batch) is well formed. No size is too large.
    package nonisolated static func acceptsBegin(name: String, size: Int, manifest: [AgentPaneUploadBatchEntry]?) -> Bool {
        guard size >= 0 else { return false }
        guard let manifest else { return true }
        return manifest.first == AgentPaneUploadBatchEntry(name: name, size: size) && manifest.allSatisfy { $0.size >= 0 }
    }

    /// The target of batch `token` when it may begin `name`, `size` bytes next.
    package func batchTarget(_ token: String, name: String, size: Int) -> Target? {
        guard let batch = batches[token], batch.authorization.accepts(name: name, size: size) else { return nil }
        return batch.target
    }

    /// Stages `name`, `size` bytes, for `target`: `make` creates its empty owner-only file for the new
    /// token and answers the file and what removing the stage removes (nil: no stage). A later file
    /// of batch `batchToken` uses that batch; a lone first file with a `manifest` of more than one
    /// starts one. The stage's token and its batch's, or nil when the batch does not take it.
    package func begin(name: String, size: Int, batchToken: String?, manifest: [AgentPaneUploadBatchEntry]?,
                       target: Target, work: BackgroundWork,
                       make: (_ token: String) -> (file: URL, removing: URL)?) -> (token: String, batchToken: String?)? {
        if let batchToken, batchTarget(batchToken, name: name, size: size) == nil { return nil }
        let token = UUID().uuidString.lowercased()
        guard let made = make(token) else { return nil }
        var batchID = batchToken
        if batchID == nil, let manifest, manifest.count > 1 {
            let id = UUID().uuidString.lowercased()
            batches[id] = Batch(target: target, authorization: AgentPaneUploadBatch(manifest))
            batchID = id
        }
        if let batchID { batches[batchID]?.authorization.begin(name: name, size: size, stage: token) }
        stages[token] = Stage(staged: Staged(target: target, file: made.file, name: name), removing: made.removing,
                              size: size, expires: Date().addingTimeInterval(Self.lifetime), batch: batchID)
        arm(work)
        return (token, batchID)
    }

    /// Appends `data`, the bytes at `offset`, to stage `token` when `owns` its target and no transfer
    /// or cleanup has it: the bytes received so far, or nil.
    package func chunk(_ token: String, offset: Int, data: Data, owns: (Target) -> Bool, work: BackgroundWork) -> Int? {
        guard var stage = stages[token], stage.idle, owns(stage.staged.target), stage.received == offset,
              data.count <= Self.chunkBytes, data.count <= stage.size - offset else { return nil }
        do {
            let handle = try FileHandle(forWritingTo: stage.staged.file)
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
        } catch { return nil }
        stage.received += data.count
        stage.expires = Date().addingTimeInterval(Self.lifetime)
        stages[token] = stage
        arm(work)
        return stage.received
    }

    /// Runs `transfer` once on stage `token`'s complete file, when `owns` its target, then removes the
    /// stage: what `transfer` answered, or nil when the stage is not there, not complete or not idle.
    /// Cancelling the caller cancels the transfer. `undo` names how to take back what an answer
    /// delivered (nil: nothing to take back); a cancel within ``lifetime`` after it runs that.
    package func finish<Answer: Sendable>(_ token: String, owns: (Target) -> Bool, work: BackgroundWork,
                                          transfer: @escaping @MainActor (Staged) async -> Answer,
                                          undo: @escaping @MainActor (Answer) -> (@MainActor () async -> Void)? = { _ in nil }) async -> Answer? {
        guard let stage = stages[token], stage.idle, owns(stage.staged.target), stage.received == stage.size else { return nil }
        let staged = stage.staged
        // task-owner: the stage's one transfer; cancel() stops it, and the stage is removed only after it returns.
        let task = Task { @MainActor [self] () -> Answer in
            let answer = await transfer(staged)
            if let undo = undo(answer) {
                delivered[token] = Delivered(target: staged.target, undo: undo, expires: Date().addingTimeInterval(Self.lifetime))
            }
            await remove(token, work: work)
            return answer
        }
        stages[token]?.transfer = Transfer(cancel: { task.cancel() }, settled: { _ = await task.value })
        arm(work)
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    /// Drops stage `token` when `owns` its target: its transfer, if one runs, stops first; the staged
    /// file is removed before this returns. A stage its transfer already delivered is taken back.
    package func cancel(_ token: String, owns: (Target) -> Bool, work: BackgroundWork) async {
        if let stage = stages[token] {
            guard owns(stage.staged.target) else { return }
            guard let transfer = stage.transfer else { await remove(token, work: work); return }
            transfer.cancel()
            await transfer.settled()
        }
        guard let done = delivered[token], owns(done.target) else { return }
        delivered.removeValue(forKey: token)
        arm(work)
        await done.undo()
    }

    /// Removes the idle stages past their deadline, the batches no stage keeps alive, and forgets
    /// deliveries too old to take back.
    package func purge(work: BackgroundWork) async {
        let now = Date()
        for token in stages.filter({ $0.value.idle && $0.value.expires < now }).map(\.key) { await remove(token, work: work) }
        batches = batches.filter { $0.value.authorization.isAlive() }
        delivered = delivered.filter { $0.value.expires >= now }
    }

    private func remove(_ token: String, work: BackgroundWork) async {
        if let cleanup = stages[token]?.cleanup { await cleanup.value; return }
        guard let stage = stages[token] else { return }
        let removing = stage.removing, batchID = stage.batch
        // task-owner: one awaited unlink on the file lane, independent of a cancelled transfer;
        // blockShutdown keeps it until the unlink completes.
        let cleanup = Task(priority: WorkPriority.userBlocking.taskPriority) { @MainActor [self] in
            _ = try? await work.run(.userBlocking, mayBlock: .files, shutdown: .blockShutdown) {
                try? FileManager.checked.removeItem(at: removing)
            }
            stages.removeValue(forKey: token)
            if let batchID {
                batches[batchID]?.authorization.release(stage: token)
                if batches[batchID]?.authorization.isComplete == true { batches.removeValue(forKey: batchID) }
            }
            arm(work)
        }
        stages[token]?.cleanup = cleanup
        arm(work)
        await cleanup.value
    }

    /// Arms the one deadline for the earliest idle stage's, ownerless batch's or delivery's expiry; nothing is
    /// pending when there is none.
    private func arm(_ work: BackgroundWork) {
        let deadlines = stages.values.compactMap { $0.idle ? $0.expires : nil } + batches.values.compactMap { $0.authorization.abandonmentDeadline }
            + delivered.values.map(\.expires)
        guard let next = deadlines.min() else { expiry.cancel(); return }
        expiry.schedule(after: .seconds(max(1, next.timeIntervalSinceNow))) { @MainActor [weak self] in
            // task-owner: one timer-fired cleanup, outside the timer's own task (which the rearm
            // below cancels); it rearms after the awaited removals, no repeating task.
            Task { @MainActor [weak self] in
                await self?.purge(work: work)
                self?.arm(work)
            }
        }
    }
}
