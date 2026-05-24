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
    @ObservationIgnored
    private var contextGeneration: UInt64 = 0
    @ObservationIgnored
    private var revertTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var revertRequestIDs: [String: UInt64] = [:]
    @ObservationIgnored
    private var revertRequestID: UInt64 = 0

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
        cancelRevertTasks()
        selectedTargetID = DiffReviewTarget.workingTreeID
        contextGeneration &+= 1

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
        cancelRevertTasks()
        contextGeneration &+= 1
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
        revertRequestID &+= 1
        let requestID = revertRequestID
        revertRequestIDs[hunk.id] = requestID
        let repositoryRoot = snapshot.repositoryRoot
        let patch = hunk.patch
        let generation = contextGeneration
        let task = Task { @MainActor [weak self] in
            do {
                try await DiffReviewGitClient.revertHunk(
                    repositoryRoot: repositoryRoot,
                    patch: patch
                )
                guard let self,
                      self.isCurrentRevert(hunkID: hunk.id, requestID: requestID),
                      self.contextGeneration == generation,
                      self.snapshot?.repositoryRoot == repositoryRoot else { return }
                self.finishRevert(hunkID: hunk.id, requestID: requestID)
                self.refresh()
            } catch is CancellationError {
                guard let self,
                      self.isCurrentRevert(hunkID: hunk.id, requestID: requestID) else { return }
                self.finishRevert(hunkID: hunk.id, requestID: requestID)
            } catch {
                guard let self,
                      self.isCurrentRevert(hunkID: hunk.id, requestID: requestID),
                      self.contextGeneration == generation,
                      self.snapshot?.repositoryRoot == repositoryRoot else { return }
                self.finishRevert(hunkID: hunk.id, requestID: requestID)
                self.phase = .failed(error.localizedDescription)
            }
        }
        revertTasks[hunk.id] = task
    }

    func stopLiveRefresh() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
    }

    func stopObserving() {
        loadTask?.cancel()
        loadTask = nil
        loadRequestID &+= 1
        contextGeneration &+= 1
        cancelRevertTasks()
        if phase.isLoading {
            phase = snapshot == nil ? .idle : .loaded
        }
        stopLiveRefresh()
    }

    private func cancelRevertTasks() {
        for task in revertTasks.values {
            task.cancel()
        }
        revertTasks.removeAll()
        revertRequestIDs.removeAll()
        revertingHunkIDs = []
    }

    private func isCurrentRevert(hunkID: String, requestID: UInt64) -> Bool {
        revertRequestIDs[hunkID] == requestID
    }

    private func finishRevert(hunkID: String, requestID: UInt64) {
        guard isCurrentRevert(hunkID: hunkID, requestID: requestID) else { return }
        revertRequestIDs[hunkID] = nil
        revertTasks[hunkID] = nil
        revertingHunkIDs.remove(hunkID)
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
