public import CmuxFoundation

/// Reloads the Ghostty configuration when the user edits a config file.
///
/// The coordinator watches every file ``GhosttyConfigLiveReloadSnapshotReading``
/// reports (top-level configs, `config-file` includes, user theme files). A
/// file event arms a trailing debounce; each further event restarts it, so an
/// editor's write-rename-chmod burst produces one evaluation. The evaluation
/// reads a fresh snapshot off the main thread and calls `reload` only when the
/// file contents differ from the baseline.
///
/// The baseline is what Ghostty last loaded, not what was on disk when a
/// reload finished. Every full reload, whoever started it, calls
/// ``noteConfigurationFilesWillLoad()`` on the main actor immediately before
/// Ghostty reads the files, and the coordinator reads the same files in that
/// turn. Two consequences follow without any timing assumption:
///
/// - A file cmux writes and then reloads itself (`cmux themes`, Settings) is in
///   the baseline once that reload reads it, so the write's own file event
///   evaluates to no change and the config reloads once.
/// - A save that lands after a reload read the files differs from the
///   baseline, so its evaluation reloads again. While a reload is still in
///   flight, `reload` queues exactly one more after it (the app coalesces
///   requests that arrive during a reload), so no save is dropped.
///
/// ``noteConfigurationDidReload()`` runs after a reload finishes and only
/// re-arms the watchers when the set of reachable files changed (an include
/// or theme was added); it never moves the baseline. After re-arming, the
/// files are read once more, so a write that landed before the new watchers
/// attached still reloads.
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
        case recordInitialBaseline
        case rearmAfterReload
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
    private var isStarted = false
    private var isStopped = false

    /// Creates a stopped coordinator. Call ``start()`` to begin watching.
    ///
    /// - Parameters:
    ///   - snapshotReader: Reads watch paths and file contents; called off the
    ///     main thread except from ``noteConfigurationFilesWillLoad()``.
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
        operationContinuation.yield(.recordInitialBaseline)
    }

    /// Records the files a full configuration load is about to read as the
    /// baseline. Call it on the main actor immediately before Ghostty reads
    /// the config files, for every full reload whoever started it.
    ///
    /// Reads the config files synchronously, alongside Ghostty's own read of
    /// the same files in this turn, so the baseline matches what was loaded.
    public func noteConfigurationFilesWillLoad() {
        guard isStarted, !isStopped else { return }
        baseline = snapshotReader.snapshot()
    }

    /// Tells the coordinator that a configuration reload finished, so the
    /// watchers follow any include or theme that reload added. Does not move
    /// the baseline: a save that landed after the reload read the files still
    /// reloads.
    public func noteConfigurationDidReload() {
        guard isStarted, !isStopped else { return }
        operationContinuation.yield(.rearmAfterReload)
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

    /// Reads a snapshot off the main thread.
    private func readSnapshot() async -> GhosttyConfigLiveReloadSnapshot {
        let reader = snapshotReader
        return await Task.detached(priority: .utility) {
            reader.snapshot()
        }.value
    }

    private func perform(_ operation: Operation) async {
        guard !isStopped else { return }
        switch operation {
        case .recordInitialBaseline:
            let snapshot = await readSnapshot()
            guard !isStopped else { return }
            // A load that started meanwhile recorded what it read; keep that.
            if baseline == nil {
                baseline = snapshot
            }
            let reloadedAfterRearm = await arm(for: snapshot)
            outcomeContinuation.yield(reloadedAfterRearm ? .reloaded : .baselineRecorded)
        case .rearmAfterReload:
            let snapshot = await readSnapshot()
            guard !isStopped else { return }
            let reloadedAfterRearm = await arm(for: snapshot)
            outcomeContinuation.yield(reloadedAfterRearm ? .reloaded : .baselineRecorded)
        case .evaluateChange:
            let snapshot = await readSnapshot()
            guard !isStopped else { return }
            let changed = !isLoaded(snapshot)
            if changed {
                // The load this starts records its own baseline through
                // noteConfigurationFilesWillLoad(); a request made while a
                // reload is in flight runs once after it.
                reload()
            }
            let reloadedAfterRearm = await arm(for: snapshot)
            outcomeContinuation.yield(changed || reloadedAfterRearm ? .reloaded : .unchanged)
        }
    }

    /// Whether `snapshot` has the contents of the last load.
    private func isLoaded(_ snapshot: GhosttyConfigLiveReloadSnapshot) -> Bool {
        baseline?.hasSameContents(as: snapshot) ?? false
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
        let recheck = await readSnapshot()
        guard !isStopped, !isLoaded(recheck) else { return false }
        // A later event re-arms again if the path set moved once more.
        reload()
        return true
    }
}
