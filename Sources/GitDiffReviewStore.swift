import Foundation
import Observation

@MainActor
@Observable
final class GitDiffReviewStore {
    private(set) var phase: GitDiffReviewPhase = .idle

    @ObservationIgnored private var rootPath: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var activeLoadGeneration: Int?
    @ObservationIgnored private var generation = 0

    deinit {
        loadTask?.cancel()
    }

    func setRootPath(_ nextRootPath: String?) {
        let normalized = Self.normalizedRootPath(nextRootPath)
        guard normalized != rootPath else {
            if case .idle = phase, normalized != nil {
                reload()
            }
            return
        }

        rootPath = normalized
        cancelCurrentLoad()

        guard normalized != nil else {
            phase = .idle
            return
        }

        reload()
    }

    func reload() {
        guard let rootPath else {
            phase = .idle
            return
        }

        generation &+= 1
        let currentGeneration = generation
        loadTask?.cancel()
        activeLoadGeneration = currentGeneration
        phase = .loading(rootPath: rootPath)
        loadTask = Task(priority: .utility) { [weak self] in
            do {
                let snapshot = try await GitDiffReviewLoader.load(rootPath: rootPath)
                try Task.checkCancellation()
                self?.completeLoad(snapshot, generation: currentGeneration)
            } catch is CancellationError {
                self?.completeFailure(.cancelled, rootPath: rootPath, generation: currentGeneration)
            } catch let error as GitDiffReviewLoadError {
                self?.completeFailure(error, rootPath: rootPath, generation: currentGeneration)
            } catch {
                self?.completeFailure(.commandFailed, rootPath: rootPath, generation: currentGeneration)
            }
        }
    }

    private func completeLoad(_ snapshot: GitDiffReviewSnapshot, generation completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        finishCurrentLoad(generation: completedGeneration)
        phase = .loaded(snapshot)
    }

    private func completeFailure(_ error: GitDiffReviewLoadError, rootPath: String, generation completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        finishCurrentLoad(generation: completedGeneration)
        if case .cancelled = error {
            phase = .idle
            return
        }
        phase = .failed(rootPath: rootPath, error: error)
    }

    private func cancelCurrentLoad() {
        generation &+= 1
        activeLoadGeneration = nil
        loadTask?.cancel()
        loadTask = nil
    }

    private func finishCurrentLoad(generation completedGeneration: Int) {
        guard activeLoadGeneration == completedGeneration else { return }
        activeLoadGeneration = nil
        loadTask = nil
    }

    private static func normalizedRootPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
