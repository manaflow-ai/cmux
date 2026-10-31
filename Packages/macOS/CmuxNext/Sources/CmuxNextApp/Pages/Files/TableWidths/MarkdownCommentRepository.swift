import CmuxNextPages
import Foundation

/// The result of a comment mutation. The encoded list is returned even when the underlying
/// attribute and fallback writes both fail so the page keeps the same best-effort update behavior.
nonisolated struct MarkdownCommentPersistenceResult: Sendable {
    let data: Data
    let written: MarkdownTableWidthWrite
    /// Monotonic mutation order for suppressing a late UI publication from an older request.
    let sequence: Int
}

/// The comment-specific operations that a Markdown file page needs. Keeping list decoding,
/// mutation, trimming and encoding in this boundary means none of that work runs on the page's
/// main actor.
nonisolated protocol MarkdownCommentStoring: Sendable {
    func read(_ path: String) async -> Data?
    func add(_ quote: ChatQuote, id: String, at path: String) async -> MarkdownCommentPersistenceResult?
    func remove(_ id: String, at path: String) async -> MarkdownCommentPersistenceResult?
}

/// Runs asynchronous repository operations one at a time. The queue lives outside the page actor
/// so an operation remains reserved while it awaits storage I/O; actor reentrancy cannot let the
/// next mutation read a stale list.
private actor MarkdownCommentMutationQueue {
    private struct Job: Sendable {
        let run: @Sendable () async -> Void
    }

    private var jobs: [Job] = []
    private var running = false

    func enqueue<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            jobs.append(Job {
                continuation.resume(returning: await operation())
            })
            startNext()
        }
    }

    private func startNext() {
        guard !running, !jobs.isEmpty else { return }
        running = true
        let job = jobs.removeFirst()
        Task { [weak self] in
            await job.run()
            await self?.finished()
        }
    }

    private func finished() {
        running = false
        startNext()
    }
}

/// Serializes comment mutations and delegates the actual attribute/fallback I/O to the existing
/// repository actor. A single actor is shared by the Markdown service, so overlapping add/delete
/// calls read, mutate and write in request order instead of losing one caller's update.
actor MarkdownCommentRepository: MarkdownCommentStoring {
    private let storage: any MarkdownTableWidthStoring
    private let mutationQueue = MarkdownCommentMutationQueue()
    private var nextSequence = 0

    init(storage: any MarkdownTableWidthStoring) {
        self.storage = storage
    }

    func read(_ path: String) async -> Data? {
        await mutationQueue.enqueue { [self] in await self.readNow(path) }
    }

    func add(_ quote: ChatQuote, id: String, at path: String) async -> MarkdownCommentPersistenceResult? {
        await mutationQueue.enqueue { [self] in await self.addNow(quote, id: id, at: path) }
    }

    func remove(_ id: String, at path: String) async -> MarkdownCommentPersistenceResult? {
        await mutationQueue.enqueue { [self] in await self.removeNow(id, at: path) }
    }

    private func readNow(_ path: String) async -> Data? {
        await storage.read(path)
    }

    private func addNow(_ quote: ChatQuote, id: String, at path: String) async -> MarkdownCommentPersistenceResult? {
        var list = await load(path) ?? ViewerCommentList()
        guard list.add(quote, id: id) else { return nil }
        nextSequence += 1
        return await save(list, at: path, sequence: nextSequence)
    }

    private func removeNow(_ id: String, at path: String) async -> MarkdownCommentPersistenceResult? {
        guard var list = await load(path), list.remove(id) else { return nil }
        nextSequence += 1
        return await save(list, at: path, sequence: nextSequence)
    }

    private func load(_ path: String) async -> ViewerCommentList? {
        guard let data = await storage.read(path) else { return nil }
        return ViewerCommentList(data: data)
    }

    private func save(_ list: ViewerCommentList, at path: String, sequence: Int) async -> MarkdownCommentPersistenceResult {
        var list = list
        list.trim(toBytes: MarkdownTableWidthRepository.commentsValueLimit)
        let data = list.data
        let written = await storage.write(path, list.comments.isEmpty ? nil : data)
        return MarkdownCommentPersistenceResult(data: data, written: written, sequence: sequence)
    }
}
