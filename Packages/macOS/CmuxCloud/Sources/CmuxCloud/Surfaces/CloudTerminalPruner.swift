import CmuxSurfaceCatalogModel

/// The outcome of pruning detached live Cloud terminals.
public struct CloudTerminalPruneResult: Sendable, Equatable {
    /// Resources whose close operation completed successfully.
    public let closed: [SurfaceResourceID]
    /// Terminal keys whose close operation failed and can be retried later.
    public let failed: [String]

    public init(closed: [SurfaceResourceID], failed: [String]) {
        self.closed = closed
        self.failed = failed
    }

    /// Whether every candidate close completed successfully.
    public var closedAll: Bool { failed.isEmpty }

    /// Whether at least one close succeeded and at least one failed.
    public var isPartial: Bool { !closed.isEmpty && !failed.isEmpty }
}

/// Selects detached live terminals and closes them with cancellation-aware
/// admission and per-terminal failure reporting.
public struct CloudTerminalPruner: Sendable {
    private let candidates: [SurfaceResourceID]

    /// Builds a pruner from one catalog snapshot. Exited and unavailable
    /// terminals are intentionally excluded by `isDetachedTerminal`.
    public init(resources: [SurfaceResource]) {
        candidates = resources.filter(\.isDetachedTerminal).map(\.id)
    }

    /// The detached terminal identities selected from the snapshot.
    public var candidateIDs: [SurfaceResourceID] { candidates }

    /// Closes each candidate until cancellation or the snapshot is exhausted.
    /// Cancellation is thrown so a caller never reports a partial success as a
    /// completed prune; ordinary close failures remain in `failed`.
    public func run(
        close: (SurfaceResourceID) async throws -> Void
    ) async throws -> CloudTerminalPruneResult {
        var closed: [SurfaceResourceID] = []
        var failed: [String] = []
        for resource in candidates {
            try Task.checkCancellation()
            do {
                try await close(resource)
                try Task.checkCancellation()
                closed.append(resource)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failed.append(resource.key)
            }
        }
        return CloudTerminalPruneResult(closed: closed, failed: failed)
    }
}
