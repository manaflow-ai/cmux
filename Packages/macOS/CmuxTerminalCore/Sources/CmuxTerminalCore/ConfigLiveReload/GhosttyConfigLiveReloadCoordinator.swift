public import CmuxFoundation

/// Reloads the Ghostty configuration when the user edits a config file.
///
/// The coordinator watches every file ``GhosttyConfigLiveReloadSnapshotReading``
/// reports (top-level configs, `config-file` includes, user theme files). A
/// change marks a reload pending and arms a trailing debounce; each further
/// change restarts it, so an editor's write-rename-chmod burst produces one
/// evaluation. The evaluation reads a fresh snapshot off the main thread and
/// calls `reload` only when file contents differ from the last applied
/// snapshot. When the set of reachable files changes (an include or theme was
/// added), the watchers are re-armed on the new set and the files are read
/// once more, so a write that landed before the new watchers attached still
/// reloads.
///
/// Reloads cmux starts itself (Reload Configuration, `cmux themes set`,
/// Settings) call ``noteConfigurationDidReload()``, which refreshes the
/// baseline. cmux writes the file before it reloads, so that write's event is
/// usually still debouncing when the reload finishes; the refreshed baseline
/// makes its evaluation a no-op instead of a second, redundant reload (which
/// would also lose the reload source cmux's theme commands rely on). The
/// trade-off: a user edit saved after Ghostty read the files but before the
/// baseline refresh is absorbed until the next save.
///
/// All state is serialized through one operation queue on the main actor;
/// file I/O happens in the injected reader and change source.
///
/// ```swift
/// let coordinator = GhosttyConfigLiveReloadCoordinator(
///     snapshotReader: reader,
///     changeSource: FileWatcherGhosttyConfigChangeSource()
/// ) {
///     GhosttyApp.shared.reloadConfiguration(source: "ghosttyConfigFileWatcher")
/// }
/// coordinator.start()
/// ```
@MainActor
public final class GhosttyConfigLiveReloadCoordinator {
    /// The default trailing debounce between the last file event and the
    /// evaluation.
    public nonisolated static let defaultDebounce: Duration = .milliseconds(300)

    /// Emits one element each time the coordinator finishes an operation.
    /// Observers (and tests) use it to follow the watcher without polling.
    public let outcomes: AsyncStream<GhosttyConfigLiveReloadOutcome>

    private enum Operation {
        case recordBaseline
        case evaluateChange
    }

    private let snapshotReader: any GhosttyConfigLiveReloadSnapshotReading
    private let changeSource: any GhosttyConfigChangeSource
    private let debounce: Duration
    private let clock: any FileWatchClock
    private let reload: @MainActor () -> Void
    private let outcomeContinuation: AsyncStream<GhosttyConfigLiveReloadOutcome>.Continuation
    private let operationContinuation: AsyncStream<Operation>.Continuation
    private let operations: AsyncStream<Operation>

    private var baseline: GhosttyConfigLiveReloadSnapshot?
    private var armedPaths: [String]?
    private var subscription: GhosttyConfigChangeSubscription?
    private var forwardingTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var hasPendingChange = false
    private var isStarted = false
    private var isStopped = false

    /// Creates a stopped coordinator. Call ``start()`` to begin watching.
    ///
    /// - Parameters:
    ///   - snapshotReader: Reads watch paths and file contents off the main
    ///     thread.
    ///   - changeSource: Watches paths for changes.
    ///   - debounce: Trailing quiet period before an evaluation. Defaults to
    ///     ``defaultDebounce``.
    ///   - clock: Drives the debounce. Defaults to ``SystemFileWatchClock``;
    ///     tests inject a clock they release by hand.
    ///   - reload: Applies the configuration. Called on the main actor only
    ///     when file contents changed.
    public init(
        snapshotReader: any GhosttyConfigLiveReloadSnapshotReading,
        changeSource: any GhosttyConfigChangeSource,
        debounce: Duration = GhosttyConfigLiveReloadCoordinator.defaultDebounce,
        clock: any FileWatchClock = SystemFileWatchClock(),
        reload: @escaping @MainActor () -> Void
    ) {
        self.snapshotReader = snapshotReader
        self.changeSource = changeSource
        self.debounce = debounce
        self.clock = clock
        self.reload = reload
        let (outcomes, outcomeContinuation) = AsyncStream<GhosttyConfigLiveReloadOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        self.outcomes = outcomes
        self.outcomeContinuation = outcomeContinuation
        let (operations, operationContinuation) = AsyncStream<Operation>.makeStream()
        self.operations = operations
        self.operationContinuation = operationContinuation
    }

    /// Records the initial baseline and starts watching. Idempotent.
    public func start() {
        guard !isStarted, !isStopped else { return }
        isStarted = true
        let operations = self.operations
        operationTask = Task { [weak self] in
            for await operation in operations {
                guard let self else { return }
                await self.perform(operation)
            }
        }
        operationContinuation.yield(.recordBaseline)
    }

    /// Tells the coordinator that the configuration was reloaded by some
    /// other path, so the files it read become the new baseline.
    public func noteConfigurationDidReload() {
        guard isStarted, !isStopped else { return }
        operationContinuation.yield(.recordBaseline)
    }

    /// Stops watching and finishes ``outcomes``. Idempotent.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        debounceTask?.cancel()
        debounceTask = nil
        forwardingTask?.cancel()
        forwardingTask = nil
        operationTask?.cancel()
        operationTask = nil
        operationContinuation.finish()
        outcomeContinuation.finish()
        if let subscription {
            self.subscription = nil
            Task { await subscription.cancel() }
        }
    }

    // MARK: - Private

    private func noteFileChange() {
        guard !isStopped else { return }
        hasPendingChange = true
        debounceTask?.cancel()
        let clock = self.clock
        let debounce = self.debounce
        // Bounded, cancellable trailing debounce behind the injected clock seam:
        // each new event cancels and re-arms it; stop() cancels it.
        debounceTask = Task { [weak self] in
            do {
                try await clock.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.operationContinuation.yield(.evaluateChange)
        }
    }

    private func perform(_ operation: Operation) async {
        guard !isStopped else { return }
        switch operation {
        case .recordBaseline:
            let snapshot = await snapshotReader.snapshot()
            guard !isStopped else { return }
            baseline = snapshot
            let reloadedAfterRearm = await arm(for: snapshot)
            outcomeContinuation.yield(reloadedAfterRearm ? .reloaded : .baselineRecorded)
        case .evaluateChange:
            hasPendingChange = false
            let snapshot = await snapshotReader.snapshot()
            guard !isStopped else { return }
            let changed = baseline.map { !$0.hasSameContents(as: snapshot) } ?? true
            baseline = snapshot
            if changed {
                reload()
            }
            let reloadedAfterRearm = await arm(for: snapshot)
            outcomeContinuation.yield(changed || reloadedAfterRearm ? .reloaded : .unchanged)
        }
    }

    /// Points the watchers at `snapshot`'s paths. When that replaces an
    /// earlier subscription, reads the files again after the new watchers are
    /// attached, because a write in between produced no event.
    ///
    /// - Returns: Whether that second read found new contents and reloaded.
    private func arm(for snapshot: GhosttyConfigLiveReloadSnapshot) async -> Bool {
        let paths = snapshot.watchedPaths
        guard paths != armedPaths else { return false }
        let isRearm = armedPaths != nil
        armedPaths = paths
        forwardingTask?.cancel()
        forwardingTask = nil
        if let previous = subscription {
            subscription = nil
            await previous.cancel()
        }
        let next = await changeSource.subscribe(toPaths: paths)
        guard !isStopped else {
            await next.cancel()
            return false
        }
        subscription = next
        forwardingTask = Task { [weak self] in
            for await _ in next.events {
                guard let self else { return }
                self.noteFileChange()
            }
        }
        guard isRearm else { return false }
        let recheck = await snapshotReader.snapshot()
        guard !isStopped, !recheck.hasSameContents(as: snapshot) else { return false }
        // A later event re-arms again if the path set moved once more.
        baseline = recheck
        reload()
        return true
    }
}
