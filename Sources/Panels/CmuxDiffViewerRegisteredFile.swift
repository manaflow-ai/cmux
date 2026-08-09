import Foundation

/// Describes one trusted file exposed through the diff-viewer URL scheme.
nonisolated struct CmuxDiffViewerRegisteredFile: Sendable {
    let requestPath: String
    let fileURL: URL
    let mimeType: String
}
