import Foundation

extension WorktreeIncludeSyncService {
    nonisolated func destinationContainer(
        destination: URL,
        inside source: URL
    ) -> URL? {
        let sourceComponents = source.pathComponents
        let destinationComponents = destination.pathComponents
        guard destinationComponents.count > sourceComponents.count,
              destinationComponents.starts(with: sourceComponents) else {
            return nil
        }
        let container = destination.deletingLastPathComponent().standardizedFileURL
        return container == source ? nil : container
    }

    nonisolated func isSafe(
        relativePath: String,
        source: URL,
        destination: URL,
        protectedSourceSubtree: URL?
    ) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath != ".git",
              !relativePath.hasPrefix(".git/") else {
            return false
        }

        let relativeComponents = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !relativeComponents.isEmpty,
              !relativeComponents.contains("..") else {
            return false
        }

        let candidate = source.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.pathComponents.starts(with: source.pathComponents) else {
            return false
        }

        let candidateComponents = candidate.pathComponents
        let destinationComponents = destination.pathComponents
        let candidateContainsDestination = destinationComponents.starts(with: candidateComponents)
        let destinationContainsCandidate = candidateComponents.starts(with: destinationComponents)
        guard !candidateContainsDestination && !destinationContainsCandidate else {
            return false
        }

        if let protectedSourceSubtree {
            let protectedComponents = protectedSourceSubtree.pathComponents
            let candidateContainsProtectedSubtree = protectedComponents.starts(with: candidateComponents)
            let protectedSubtreeContainsCandidate = candidateComponents.starts(with: protectedComponents)
            if candidateContainsProtectedSubtree || protectedSubtreeContainsCandidate {
                return false
            }
        }
        return true
    }
}
