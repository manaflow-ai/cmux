import Combine
import Foundation

@MainActor
final class DiffReviewStore: ObservableObject {
    // @Observable is macOS 14+; cmux still targets macOS 13.
    @Published private(set) var phase: DiffReviewLoadPhase = .idle
    @Published private(set) var snapshot: DiffReviewSnapshot?
    @Published private(set) var selectedTargetID = DiffReviewTarget.workingTreeID
    @Published private(set) var revertingHunkIDs: Set<String> = []

    private var directory: String?
    private var loadTask: Task<Void, Never>?
    private var liveRefreshTimer: Timer?

    var isLoading: Bool { phase.isLoading }

    func setDirectory(_ nextDirectory: String?) {
        let trimmedDirectory = nextDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDirectory = trimmedDirectory?.isEmpty == false ? trimmedDirectory : nil
        guard directory != normalizedDirectory else {
            startLiveRefreshIfNeeded()
            return
        }

        directory = normalizedDirectory
        snapshot = nil
        revertingHunkIDs = []
        selectedTargetID = DiffReviewTarget.workingTreeID

        if normalizedDirectory == nil {
            phase = .idle
            stopLiveRefresh()
        } else {
            refresh()
            startLiveRefreshIfNeeded()
        }
    }

    func selectTarget(id: String) {
        guard selectedTargetID != id else { return }
        selectedTargetID = id
        refresh()
    }

    func refresh() {
        guard let directory else {
            phase = .idle
            snapshot = nil
            return
        }

        loadTask?.cancel()
        phase = .loading
        let targetID = selectedTargetID
        loadTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await DiffReviewGitClient.loadSnapshot(
                    directory: directory,
                    selectedTargetID: targetID
                )
                guard !Task.isCancelled else { return }
                self?.snapshot = snapshot
                self?.selectedTargetID = snapshot.selectedTarget.id
                self?.phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func revertHunk(_ hunk: DiffReviewHunk) {
        guard let snapshot, snapshot.selectedTarget.allowsHunkRevert else { return }
        guard !revertingHunkIDs.contains(hunk.id) else { return }

        revertingHunkIDs.insert(hunk.id)
        let repositoryRoot = snapshot.repositoryRoot
        let patch = hunk.patch
        Task { @MainActor [weak self] in
            do {
                try await DiffReviewGitClient.revertHunk(
                    repositoryRoot: repositoryRoot,
                    patch: patch
                )
                guard let self else { return }
                self.revertingHunkIDs.remove(hunk.id)
                self.refresh()
            } catch {
                guard let self else { return }
                self.revertingHunkIDs.remove(hunk.id)
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func stopLiveRefresh() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }

    private func startLiveRefreshIfNeeded() {
        guard directory != nil, liveRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.directory != nil else { return }
                guard !self.phase.isLoading, self.revertingHunkIDs.isEmpty else { return }
                self.refresh()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        liveRefreshTimer = timer
    }

    @MainActor
    deinit {
        loadTask?.cancel()
        liveRefreshTimer?.invalidate()
    }
}
