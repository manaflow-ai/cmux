import Foundation
public import CmuxCore

/// An actor-backed live catalog. A failed reload never replaces the last-known-
/// good snapshot, so a typo in an override cannot disable detection for every
/// existing session.
public actor CmuxAgentManifestStore {
    private let loader: CmuxAgentManifestLoader
    private var currentSnapshot: CmuxAgentManifestSnapshot
    private var nextGeneration: UInt64 = 1
    private var lastReloadError: CmuxAgentManifestLoadError?
    private var watchTask: Task<Void, Never>?
    private var updateContinuations: [
        UUID: AsyncStream<CmuxAgentManifestSnapshot>.Continuation
    ] = [:]

    /// Creates an actor-backed catalog and installs a last-known-good snapshot.
    ///
    /// - Parameters:
    ///   - loader: The loader used for every subsequent reload.
    ///   - initialSnapshot: An optional last-known-good snapshot to install
    ///     when the first on-disk load failed. This lets a watcher observe the
    ///     user's repair without disabling the bundled catalog.
    ///   - initialError: The error that caused ``initialSnapshot`` to be used.
    ///     It remains available from ``reloadError()`` until reload succeeds.
    /// - Throws: ``CmuxAgentManifestLoadError`` when no initial snapshot was
    ///   supplied and the loader cannot publish its first catalog.
    public init(
        loader: CmuxAgentManifestLoader,
        initialSnapshot: CmuxAgentManifestSnapshot? = nil,
        initialError: CmuxAgentManifestLoadError? = nil
    ) throws {
        let snapshot = try initialSnapshot ?? loader.load()
        self.loader = loader
        self.currentSnapshot = snapshot
        self.lastReloadError = initialError
        self.nextGeneration = snapshot.generation == UInt64.max
            ? UInt64.max
            : snapshot.generation &+ 1
    }

    deinit {
        watchTask?.cancel()
        for continuation in updateContinuations.values {
            continuation.finish()
        }
    }

    /// Returns the currently accepted snapshot.
    public func snapshot() -> CmuxAgentManifestSnapshot { currentSnapshot }

    /// Creates an independent broadcast subscription for accepted generations.
    ///
    /// - Returns: A newest-value-buffered stream that receives every later
    ///   accepted generation until its consumer terminates.
    public func updates() -> AsyncStream<CmuxAgentManifestSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CmuxAgentManifestSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(id: id) }
        }
        updateContinuations[id] = continuation
        return stream
    }

    /// Reloads from disk, retaining the current snapshot when validation fails.
    public func reload() -> Result<CmuxAgentManifestSnapshot, CmuxAgentManifestLoadError> {
        do {
            let snapshot = try loader.load(generation: nextGeneration)
            // Directory watchers can fire while an atomic save temporarily
            // removes the destination, and can also emit several invalidations
            // for one edit. Do not publish a new generation unless the accepted
            // rule catalog actually changed; consumers should never observe an
            // intermediate reversion to the bundled snapshot.
            guard snapshot.entries != currentSnapshot.entries else {
                lastReloadError = nil
                return .success(currentSnapshot)
            }
            nextGeneration = nextGeneration == UInt64.max ? UInt64.max : nextGeneration &+ 1
            currentSnapshot = snapshot
            lastReloadError = nil
            for continuation in updateContinuations.values {
                continuation.yield(snapshot)
            }
            return .success(snapshot)
        } catch let error as CmuxAgentManifestLoadError {
            lastReloadError = error
            return .failure(error)
        } catch {
            let wrapped = CmuxAgentManifestLoadError.invalidFile(
                path: "",
                reason: error.localizedDescription
            )
            lastReloadError = wrapped
            return .failure(wrapped)
        }
    }

    /// Returns the most recent reload error, if any.
    public func reloadError() -> CmuxAgentManifestLoadError? { lastReloadError }

    /// Starts event-driven reloads from a filesystem invalidation stream.
    ///
    /// - Parameter events: Invalidations emitted by the caller-owned watcher.
    public func startWatching(events: AsyncStream<Void>) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            for await _ in events {
                guard !Task.isCancelled else { return }
                _ = await self?.reload()
            }
        }
    }

    /// Stops the active reload task; it is safe to call repeatedly.
    public func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func removeUpdateContinuation(id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }
}
