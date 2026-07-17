import Foundation

/// Internal file metadata plus the exact patch bytes used for hashing and parsing.
struct GitDiffFile: Sendable, Equatable {
    let summary: DiffFileSummary
    let patch: Data
}
