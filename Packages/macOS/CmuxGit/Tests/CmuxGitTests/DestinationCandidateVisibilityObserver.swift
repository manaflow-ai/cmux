import Foundation

// This test-only observer is used by one synchronous copy call; its mutable
// observations are confined to that serialized call path.
final class DestinationCandidateVisibilityObserver: @unchecked Sendable {
    private let candidate: URL
    private(set) var candidateVisibility: [Bool] = []

    init(candidate: URL) {
        self.candidate = candidate.standardizedFileURL
    }

    func observe(_: URL) {
        candidateVisibility.append(
            FileManager.default.fileExists(atPath: candidate.path)
        )
    }
}
