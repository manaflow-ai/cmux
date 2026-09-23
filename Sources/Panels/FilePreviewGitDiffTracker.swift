import CmuxFilePreviewCore
import CmuxGit
import Foundation

/// Keeps the git line changes that the File Preview gutter paints.
///
/// - The base is the file at HEAD, read as bytes through
///   ``GitHeadContentReading`` and decoded with the buffer's own encoding.
/// - Buffer edits are debounced on the injected clock and diffed off the main
///   actor, keeping the typing path free of diff work.
/// - Moves of HEAD are detected by watching `HEAD`, the index, and the branch
///   ref. A change whose HEAD bytes did not move skips the diff, and only a
///   change to `HEAD` itself, such as a checkout, resolves the watched set
///   again.
/// - Repository observations and ``updates`` are released on ``cancel()`` or,
///   when an owner drops the tracker without cancelling, on deinit.
/// - Results are yielded on ``updates``, which keeps only the latest value
///   when the consumer falls behind.
@MainActor
final class FilePreviewGitDiffTracker {
    let updates: AsyncStream<FilePreviewGitGutterMarkers>

    private let filePath: String
    private let reader: any GitHeadContentReading
    private let diff: FilePreviewGitLineDiff
    private let debounce: Duration
    private let clock: any Clock<Duration>
    private let continuation: AsyncStream<FilePreviewGitGutterMarkers>.Continuation

    private var hasReadBase = false
    private var baseData: Data?
    private var baseContent: String?
    private var encoding: String.Encoding = .utf8
    private var latestText = ""
    private var markers = FilePreviewGitGutterMarkers.untracked
    private var baseTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    /// A detached diff ignores cancellation, so a late result is dropped by generation.
    private var recomputeGeneration = 0
    private var watchResolutionTask: Task<Void, Never>?
    private weak var watchCoordinator: FileContentChangeCoordinator?
    private var watchedPaths: [String]?
    private var observationIDs: [UUID] = []
    private var observationLifetime: FileContentObservationLifetime?
    /// Registration reports once per path; the install performs one base read instead.
    private var isInstallingObservations = false

    init(
        filePath: String,
        reader: any GitHeadContentReading = SystemGitHeadContentReader(),
        diff: FilePreviewGitLineDiff = FilePreviewGitLineDiff(),
        debounce: Duration = .milliseconds(150),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.filePath = filePath
        self.reader = reader
        self.diff = diff
        self.debounce = debounce
        self.clock = clock
        (updates, continuation) = AsyncStream.makeStream(
            of: FilePreviewGitGutterMarkers.self,
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    deinit {
        continuation.finish()
    }

    /// Starts watching the repository through `coordinator` and loads the
    /// base.
    ///
    /// Files outside a repository have nothing to watch, so the base is read
    /// once and resolves to untracked.
    func startWatchingRepository(using coordinator: FileContentChangeCoordinator) {
        stopWatchingRepository()
        watchCoordinator = coordinator
        resolveWatchedPaths()
    }

    func stopWatchingRepository() {
        watchResolutionTask?.cancel()
        watchResolutionTask = nil
        removeObservations()
        watchedPaths = nil
        watchCoordinator = nil
    }

    /// Reads which paths move HEAD content and installs observations when
    /// the set changed, such as after a branch checkout.
    private func resolveWatchedPaths() {
        watchResolutionTask?.cancel()
        let reader = reader
        let filePath = filePath
        watchResolutionTask = Task { [weak self] in
            let paths = await reader.watchedPaths(forFile: filePath) ?? []
            guard !Task.isCancelled, let self else { return }
            self.installObservations(for: paths)
        }
    }

    private func installObservations(for paths: [String]) {
        guard paths != watchedPaths else { return }
        removeObservations()
        watchedPaths = paths
        if let coordinator = watchCoordinator {
            isInstallingObservations = true
            observationIDs = paths.map { path in
                let movesBranch = URL(fileURLWithPath: path).lastPathComponent == "HEAD"
                return coordinator.observe(path: path) { [weak self] in
                    self?.handleRepositoryChange(movesBranch: movesBranch)
                }
            }
            isInstallingObservations = false
            let ids = observationIDs
            observationLifetime = FileContentObservationLifetime {
                Task { @MainActor in
                    ids.forEach { coordinator.removeObservation($0) }
                }
            }
        }
        refreshBase()
    }

    private func removeObservations() {
        observationLifetime?.cancel()
        observationLifetime = nil
        observationIDs.forEach { watchCoordinator?.removeObservation($0) }
        observationIDs = []
    }

    private func handleRepositoryChange(movesBranch: Bool) {
        guard !isInstallingObservations else { return }
        refreshBase()
        if movesBranch {
            resolveWatchedPaths()
        }
    }

    /// Rereads the HEAD base and recomputes the markers immediately when it
    /// changed.
    func refreshBase() {
        baseTask?.cancel()
        let reader = reader
        let filePath = filePath
        baseTask = Task { [weak self] in
            let data = await reader.headContent(forFile: filePath)
            guard !Task.isCancelled, let self else { return }
            if self.hasReadBase, self.baseData == data { return }
            self.hasReadBase = true
            self.baseData = data
            self.decodeBase()
            self.recompute(debounced: false)
        }
    }

    /// Records the encoding the buffer was loaded with and redecodes the base.
    func update(encoding: String.Encoding) {
        guard encoding != self.encoding else { return }
        self.encoding = encoding
        guard hasReadBase else { return }
        decodeBase()
        recompute(debounced: false)
    }

    /// Records the latest buffer text and schedules a debounced diff.
    ///
    /// Diffing waits for the first base so the initial load does not flash
    /// every line as added.
    func update(currentText: String) {
        latestText = currentText
        guard baseContent != nil else { return }
        recompute(debounced: true)
    }

    /// Stops all work and finishes ``updates``.
    func cancel() {
        baseTask?.cancel()
        baseTask = nil
        recomputeTask?.cancel()
        recomputeTask = nil
        recomputeGeneration += 1
        stopWatchingRepository()
        continuation.finish()
    }

    private func decodeBase() {
        baseContent = baseData.flatMap { String(data: $0, encoding: encoding) }
    }

    /// Recomputes the markers. A missing base means the file is untracked or
    /// undecodable, so the markers clear.
    private func recompute(debounced: Bool) {
        recomputeTask?.cancel()
        recomputeGeneration += 1
        let generation = recomputeGeneration
        guard let baseContent else {
            recomputeTask = nil
            publish(.untracked)
            return
        }
        let current = latestText
        let diff = diff
        let clock = clock
        let delay = debounced ? debounce : nil
        recomputeTask = Task { [weak self] in
            if let delay {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
            }
            let next = await Task.detached(priority: .utility) {
                diff.changes(base: baseContent, current: current)
            }.value
            guard let self, self.recomputeGeneration == generation else { return }
            self.publish(FilePreviewGitGutterMarkers(isTracked: true, changes: next))
        }
    }

    private func publish(_ next: FilePreviewGitGutterMarkers) {
        guard next != markers else { return }
        markers = next
        continuation.yield(next)
    }
}
