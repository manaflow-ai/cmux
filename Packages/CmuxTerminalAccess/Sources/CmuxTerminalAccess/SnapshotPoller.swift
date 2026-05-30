// SPDX-License-Identifier: MIT

import Foundation

/// Polled dirty-detector for `mode=cells` SSE streams (D8).
///
/// At each tick interval the poller calls ``read`` to obtain a fresh
/// ``CellGrid``, computes ``CellGridDigest`` over it, and only invokes
/// ``emit`` when the digest differs from the previous tick. This avoids
/// emitting redundant snapshots when the screen is idle.
///
/// The dirty notifier is intentionally polling-based (NOT a ghostty
/// renderer callback) — adding a third ghostty patch was out of scope
/// for v1; see plan §15 open question. Tradeoffs: small wasted work
/// per tick when idle; tunable interval; deterministic in tests via
/// the injected ``MonotonicClock``.
public actor SnapshotPoller {
    /// Tick interval in seconds. Default 0.2s (5 Hz).
    public let interval: Double

    private let clock: any MonotonicClock
    private let read: @Sendable () async throws -> CellGrid
    private let emit: @Sendable (CellGrid) async -> Void

    /// Last emitted digest; nil before the first tick.
    private var lastDigest: UInt64?

    /// Last tick instant (monotonic seconds). Tests can inspect.
    private(set) var lastTickAt: Double = -Double.infinity

    /// Whether the poll loop should keep running. Toggled by ``stop()``.
    private var running: Bool = false

    /// Creates a poller. ``start()`` does not begin until called.
    ///
    /// - Parameters:
    ///   - interval: Tick interval in seconds (must be positive).
    ///   - clock: Injectable monotonic clock; production uses
    ///     ``SystemMonotonicClock``, tests use ``ManualClock``.
    ///   - read: Async closure returning the current ``CellGrid``.
    ///   - emit: Async closure called with each emitted grid.
    public init(
        interval: Double = 0.2,
        clock: any MonotonicClock = SystemMonotonicClock(),
        read: @escaping @Sendable () async throws -> CellGrid,
        emit: @escaping @Sendable (CellGrid) async -> Void
    ) {
        precondition(interval > 0)
        self.interval = interval
        self.clock = clock
        self.read = read
        self.emit = emit
    }

    /// Runs one tick: reads the grid, digests, emits on change. Used
    /// by tests with a ``ManualClock`` to step the poller without real
    /// sleeps. In production ``start()`` drives ticks itself.
    public func tick() async throws {
        let now = clock.now()
        lastTickAt = now
        let grid = try await read()
        let d = CellGridDigest.compute(grid)
        if d != lastDigest {
            lastDigest = d
            await emit(grid)
        }
    }

    /// Begins the polling loop. Returns immediately; the loop runs on
    /// the actor's task until ``stop()`` is called.
    public func start() async {
        guard !running else { return }
        running = true
        Task { [weak self] in
            while await self?.shouldKeepRunning() == true {
                do { try await self?.tick() }
                catch { /* swallow — caller emits via read closure errors */ }
                try? await Task.sleep(nanoseconds: UInt64(self?.interval ?? 0.2) * 1_000_000_000)
            }
        }
    }

    /// Stops the polling loop on the next iteration boundary.
    public func stop() async {
        running = false
    }

    /// Internal helper used by the polling task.
    func shouldKeepRunning() -> Bool { running }
}
