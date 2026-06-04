import Foundation

/// Bounds how many git-metadata probes parse index files at the same time.
///
/// Each tracked workspace panel schedules a detached probe that reads and
/// parses the entire `.git/index`. A burst — a workspace restore, the periodic
/// fallback refresh, or a flurry of file-system watch events — can schedule one
/// probe per panel at once. With dozens of panels that spawns dozens of
/// parallel parses and saturates every core, producing the multi-core CPU
/// spikes tracked in https://github.com/manaflow-ai/cmux/issues/4639.
///
/// This actor caps how many probes run concurrently. Callers wrap the parse in
/// ``run(_:)``; work beyond the cap suspends until a slot frees and resumes in
/// FIFO order. Construct one and share it across every probe:
///
/// ```swift
/// let limiter = GitProbeConcurrencyLimiter(maxConcurrent: 4)
/// let snapshot = await limiter.run { await parseIndex() }
/// ```
public actor GitProbeConcurrencyLimiter {
    private let maxConcurrent: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a limiter allowing at most `maxConcurrent` probes to run at once.
    ///
    /// - Parameter maxConcurrent: The concurrency ceiling. Values below 1 are
    ///   clamped to 1 so the limiter always makes forward progress.
    public init(maxConcurrent: Int) {
        let ceiling = max(1, maxConcurrent)
        self.maxConcurrent = ceiling
        self.available = ceiling
    }

    /// Runs `body` once a slot is free, releasing the slot when it returns.
    ///
    /// While `body` is suspended on its own `await`s the actor is free to admit
    /// other callers up to the ceiling; only the slot accounting is serialized.
    ///
    /// - Parameter body: The probe work to run while holding a slot.
    /// - Returns: Whatever `body` returns.
    public func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        // Resumed by `release()`, which hands off its slot directly without
        // bumping `available`, so the slot count stays balanced.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
