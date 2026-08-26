import Foundation

/// Mutable state for one synchronous, bounded config traversal.
nonisolated struct GitConfigTraversalState: Sendable {
    var budget: GitConfigTraversalBudget
    var seenConfigPaths: Set<String> = []
    var configURLs: [URL] = []
    var referenceStorageName: String?
    var referenceStoragePaths: [String] = []
    var worktreeConfigEnabled = false
    var objectFormatSHA256 = false
}
