import CmuxFilePreviewCore
import CmuxGit
import Foundation

/// Keeps the git line changes that the File Preview gutter paints.
///
/// - The base is the HEAD commit.
/// - Buffer edits are debounced and diffed off the main actor, keeping typing unblocked.
/// - Commits and staging are detected through the index and reload the base.
@MainActor
final class FilePreviewGitDiffTracker {
    /// Coalesces a burst of keystrokes into one diff.
    private static let recomputeDebounce = Duration.milliseconds(150)

    private let filePath: String
    private let reader: GitHeadFileContentReader
    private let onChange: @MainActor ([Int: FilePreviewGitLineChange]) -> Void

    private var baseContent: String?
    private var latestText = ""
    private var baseTask: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    /// Prevents a late diff from overwriting a newer result.
    private var recomputeGeneration = 0
    private var indexObservationID: UUID?
    private weak var indexCoordinator: FileContentChangeCoordinator?
    /// Invalidates a pending index watch aimed at a previous coordinator.
    private var indexWatchGeneration = 0

    private(set) var changes: [Int: FilePreviewGitLineChange] = [:]

    init(
        filePath: String,
        reader: GitHeadFileContentReader = GitHeadFileContentReader(),
        onChange: @escaping @MainActor ([Int: FilePreviewGitLineChange]) -> Void
    ) {
        self.filePath = filePath
        self.reader = reader
        self.onChange = onChange
    }

    /// Starts watching the repository index.
    ///
    /// Files outside a repository have no index and are not watched.
    func startWatchingIndex(using coordinator: FileContentChangeCoordinator) {
        stopWatchingIndex()
        let reader = reader
        let filePath = filePath
        let generation = indexWatchGeneration
        Task { [weak self, weak coordinator] in
            guard let indexPath = await reader.indexPath(forFile: filePath) else { return }
            guard let self, let coordinator else { return }
            guard self.indexWatchGeneration == generation, self.indexObservationID == nil else {
                return
            }
            self.indexCoordinator = coordinator
            self.indexObservationID = coordinator.observe(path: indexPath) { [weak self] in
                self?.refreshBase()
            }
        }
    }

    func stopWatchingIndex() {
        indexWatchGeneration += 1
        if let indexObservationID {
            self.indexObservationID = nil
            indexCoordinator?.removeObservation(indexObservationID)
        }
        indexCoordinator = nil
    }

    /// Rereads the HEAD base and recomputes the markers.
    func refreshBase() {
        baseTask?.cancel()
        let reader = reader
        let filePath = filePath
        baseTask = Task { [weak self] in
            let content = await reader.headContent(forFile: filePath)
            guard !Task.isCancelled, let self else { return }
            self.baseContent = content
            self.recomputeNow()
        }
    }

    /// Records the latest buffer text.
    ///
    /// Skips diffing until a base exists, avoiding a flash during the first load.
    func update(currentText: String) {
        latestText = currentText
        guard baseContent != nil else { return }
        recompute(debounced: true)
    }

    func cancel() {
        baseTask?.cancel()
        baseTask = nil
        recomputeTask?.cancel()
        recomputeTask = nil
        recomputeGeneration += 1
        stopWatchingIndex()
    }

    private func recomputeNow() {
        recompute(debounced: false)
    }

    /// Recomputes the markers.
    ///
    /// A missing base means the file is untracked, so the markers are cleared.
    private func recompute(debounced: Bool) {
        recomputeTask?.cancel()
        recomputeGeneration += 1
        let generation = recomputeGeneration
        guard let baseContent else {
            recomputeTask = nil
            publish([:])
            return
        }
        let current = latestText
        recomputeTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: Self.recomputeDebounce)
                guard !Task.isCancelled else { return }
            }
            let next = await Task.detached(priority: .utility) {
                FilePreviewGitLineDiff.changes(base: baseContent, current: current)
            }.value
            guard let self, self.recomputeGeneration == generation else { return }
            self.publish(next)
        }
    }

    private func publish(_ next: [Int: FilePreviewGitLineChange]) {
        guard next != changes else { return }
        changes = next
        onChange(next)
    }
}
