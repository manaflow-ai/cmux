import Foundation

/// Runs one encoded sidecar request (a `DiffRequest` JSON object) and returns
/// its encoded `DiffResponse`. Tests use a fake that speaks the same JSON.
nonisolated protocol DiffSidecarRunning: Sendable {
    func run(_ request: Data) async throws -> Data
}

/// The bundled sidecar: `bin/cmux-diff-sidecar rpc --root <session root> --cmux
/// <bundled bin/cmux> --resource-scheme page --process-group-ready`, one child
/// per request (diff-host.md decision a).
nonisolated struct DiffSidecarLauncher: DiffSidecarRunning {
    let sidecar: URL
    let cmux: URL
    let root: URL
    var limits = DiffSidecarProcess.Limits()

    /// The app bundle's `bin/cmux-diff-sidecar` and `bin/cmux`, nil when either
    /// is missing or not executable.
    static func bundled(root: URL, resources: URL? = Bundle.main.resourceURL) -> DiffSidecarLauncher? {
        guard let bin = resources?.appending(path: "bin", directoryHint: .isDirectory) else { return nil }
        let sidecar = bin.appending(path: "cmux-diff-sidecar"), cmux = bin.appending(path: "cmux")
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: sidecar.path), manager.isExecutableFile(atPath: cmux.path) else { return nil }
        return DiffSidecarLauncher(sidecar: sidecar, cmux: cmux, root: root)
    }

    var arguments: [String] {
        ["rpc", "--root", root.path, "--cmux", cmux.path, "--resource-scheme", "page", "--process-group-ready"]
    }

    func run(_ request: Data) async throws -> Data {
        try await DiffSidecarProcess.run(executable: sidecar, arguments: arguments, request: request, limits: limits)
    }
}

/// At most `limit` sidecar children at once (4, as classic), the rest wait in
/// arrival order up to `queueLimit`; past that a request fails `busy` at once.
/// A cancelled waiter leaves the queue without taking a slot.
actor DiffSidecarPool: DiffSidecarRunning {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let runner: any DiffSidecarRunning
    private let limit: Int
    private let queueLimit: Int
    private var active = 0
    private var waiters: [Waiter] = []

    init(runner: any DiffSidecarRunning, limit: Int = 4, queueLimit: Int = 32) {
        precondition(limit > 0)
        self.runner = runner
        self.limit = limit
        self.queueLimit = queueLimit
    }

    nonisolated func run(_ request: Data) async throws -> Data {
        try await acquire()
        do {
            let reply = try await runner.run(request)
            await release()
            return reply
        } catch {
            await release()
            throw error
        }
    }

    /// Requests running now (tests).
    var running: Int { active }

    private func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        guard waiters.count < queueLimit else { throw DiffSidecarError.busy }
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            // task-owner: one hop onto the pool to drop this waiter; ends at once
            Task { await self.cancelWaiter(id) }
        }
        guard granted else { throw CancellationError() }
        // The slot was handed over in `release`; give it back when cancelled meanwhile.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        guard !waiters.isEmpty else {
            active -= 1
            return
        }
        // The slot passes to the next waiter: `active` stays the same.
        waiters.removeFirst().continuation.resume(returning: true)
    }
}
