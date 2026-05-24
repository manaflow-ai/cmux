import Foundation
import Observation

@MainActor
@Observable
final class DiffReviewStore {
    private(set) var phase: DiffReviewLoadPhase = .idle
    private(set) var snapshot: DiffReviewSnapshot?
    private(set) var selectedTargetID = DiffReviewTarget.workingTreeID
    private(set) var revertingHunkIDs: Set<String> = []

    @ObservationIgnored
    private var directory: String?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var liveRefreshTimer: Timer?
    @ObservationIgnored
    private var loadRequestID: UInt64 = 0

    var isLoading: Bool { phase.isLoading }

    func setDirectory(_ nextDirectory: String?) {
        let trimmedDirectory = nextDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDirectory = trimmedDirectory?.isEmpty == false ? trimmedDirectory : nil
        guard directory != normalizedDirectory else {
            resumeObservingCurrentDirectory()
            return
        }

        directory = normalizedDirectory
        snapshot = nil
        revertingHunkIDs = []
        selectedTargetID = DiffReviewTarget.workingTreeID

        if normalizedDirectory == nil {
            loadTask?.cancel()
            loadTask = nil
            loadRequestID &+= 1
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
        loadRequestID &+= 1
        let requestID = loadRequestID
        phase = .loading
        let targetID = selectedTargetID
        loadTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await DiffReviewGitClient.loadSnapshot(
                    directory: directory,
                    selectedTargetID: targetID
                )
                guard let self, !Task.isCancelled, self.loadRequestID == requestID else { return }
                self.snapshot = snapshot
                self.selectedTargetID = snapshot.selectedTarget.id
                self.phase = .loaded
                self.loadTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.loadRequestID == requestID else { return }
                self.phase = .failed(error.localizedDescription)
                self.loadTask = nil
            }
        }
    }

    func revertHunk(_ hunk: DiffReviewHunk) {
        guard phase.allowsLiveRefresh else { return }
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

    func stopObserving() {
        loadTask?.cancel()
        loadTask = nil
        loadRequestID &+= 1
        if phase.isLoading {
            phase = snapshot == nil ? .idle : .loaded
        }
        stopLiveRefresh()
    }

    private func resumeObservingCurrentDirectory() {
        guard directory != nil else {
            stopLiveRefresh()
            return
        }
        if snapshot == nil || phase == .idle || phase.allowsLiveRefresh {
            refresh()
        }
        startLiveRefreshIfNeeded()
    }

    private func startLiveRefreshIfNeeded() {
        guard directory != nil, liveRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.directory != nil else { return }
                guard self.phase.allowsLiveRefresh, self.revertingHunkIDs.isEmpty else { return }
                self.refresh()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        liveRefreshTimer = timer
    }

}
