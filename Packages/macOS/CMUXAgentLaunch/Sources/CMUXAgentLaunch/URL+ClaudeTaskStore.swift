import Foundation

extension URL {
    /// Resolves aliases before a Claude task-store directory participates in I/O or identity.
    var canonicalClaudeTaskStoreDirectoryURL: URL {
        resolvingSymlinksInPath().standardizedFileURL
    }
}
