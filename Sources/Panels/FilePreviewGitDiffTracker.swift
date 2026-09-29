import CmuxFilePreviewCore
import CmuxGit
import Foundation

/// Keeps the git line changes that the File Preview gutter paints.
///
/// - The base is the file at HEAD, read as bytes through
///   ``GitHeadContentReading`` and decoded with the buffer's own encoding.
/// - Buffer edits are diffed off the main actor, one diff at a time. Edits
///   that arrive while a diff runs coalesce into one rerun on the latest
///   buffer, so typing never queues diff work.
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
    private let continuation: AsyncStream<FilePreviewGitGutterMarkers>.Continuation

    private var hasReadBase = false
    private var baseData: Data?
    private var baseContent: String?
    private var encoding: String.Encoding = .utf8
    private var latestText = ""
    private var hasBufferText = false
    private var markers = FilePreviewGitGutterMarkers.untracked
    private var baseTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    /// Advances with every input change, so a diff that finishes behind the
    /// latest input reruns instead of publishing.
    private var inputGeneration = 0
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
        diff: FilePreviewGitLineDiff = FilePreviewGitLineDiff()
    ) {
        self.filePath = filePath
        self.reader = reader
        self.diff = diff
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
            self.scheduleDiff()
        }
    }

    /// Records the encoding the buffer was loaded with and redecodes the base.
    func update(encoding: String.Encoding) {
        guard encoding != self.encoding else { return }
        self.encoding = encoding
        guard hasReadBase else { return }
        decodeBase()
        scheduleDiff()
    }

    /// Records the latest buffer text and schedules a diff.
    ///
    /// Call it only with text loaded from the file or edited by the user.
    /// Diffing waits until both the base and the buffer have arrived, so a
    /// base read that finishes before the file loads does not flash markers
    /// against an empty buffer.
    func update(currentText: String) {
        latestText = currentText
        hasBufferText = true
        scheduleDiff()
    }

    /// Stops all work and finishes ``updates``.
    func cancel() {
        baseTask?.cancel()
        baseTask = nil
        diffTask?.cancel()
        diffTask = nil
        stopWatchingRepository()
        continuation.finish()
    }

    private func decodeBase() {
        baseContent = baseData.flatMap { String(data: $0, encoding: encoding) }
    }

    /// Marks the input changed and starts a diff unless one is running.
    ///
    /// A running diff sees the newer generation when it finishes and starts
    /// the rerun itself.
    private func scheduleDiff() {
        inputGeneration += 1
        guard diffTask == nil else { return }
        startDiff()
    }

    /// Diffs the latest input. A missing base means the file is untracked or
    /// undecodable, so the markers clear.
    private func startDiff() {
        guard hasReadBase else { return }
        guard let baseContent else {
            publish(.untracked)
            return
        }
        guard hasBufferText else { return }
        let generation = inputGeneration
        let current = latestText
        let diff = diff
        diffTask = Task { [weak self] in
            let next = await Task.detached(priority: .utility) {
                diff.changes(base: baseContent, current: current)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.diffTask = nil
            if self.inputGeneration == generation {
                self.publish(FilePreviewGitGutterMarkers(isTracked: true, changes: next))
            } else {
                self.startDiff()
            }
        }
    }

    private func publish(_ next: FilePreviewGitGutterMarkers) {
        guard next != markers else { return }
        markers = next
        continuation.yield(next)
    }
}
