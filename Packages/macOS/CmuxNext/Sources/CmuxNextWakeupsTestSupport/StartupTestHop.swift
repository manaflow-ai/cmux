import CmuxNextCompat
public import CmuxNextWakeups

/// A main hop the test runs by hand.
public final class StartupTestHop: Sendable {
    private let queued = Mutex<[@MainActor @Sendable () -> Void]>([])

    public init() {}

    /// The hop to pass to a ``StartupScheduler``.
    public var hop: StartupMainHop {
        StartupMainHop { [self] work in queued.withLock { $0.append(work) } }
    }

    /// The hops queued and not run yet.
    public var count: Int { queued.withLock { $0.count } }

    /// Runs every queued hop, and the hops they queue.
    ///
    /// - Returns: How many ran.
    @MainActor @discardableResult public func drain() -> Int {
        var ran = 0
        var batch = take()
        while !batch.isEmpty {
            for work in batch { work() }
            ran += batch.count
            batch = take()
        }
        return ran
    }

    private func take() -> [@MainActor @Sendable () -> Void] {
        queued.withLock { queued in
            defer { queued = [] }
            return queued
        }
    }
}
