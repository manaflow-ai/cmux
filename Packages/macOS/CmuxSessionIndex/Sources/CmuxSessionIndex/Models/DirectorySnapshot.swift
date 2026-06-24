public import Foundation

/// Immutable per-directory snapshot consumed by the "Show more" session popover for
/// empty-query scrolling.
///
/// All entries are merged across the agent sources and sorted by `modified` descending.
/// The popover slices this array in-memory to page, so scrolling fires zero store/disk
/// calls. `cwd` is the absolute directory path; `""` represents the unknown-folder bucket.
public struct DirectorySnapshot: Sendable {
    public let cwd: String
    public let entries: [SessionEntry]
    public let errors: [String]

    public init(cwd: String, entries: [SessionEntry], errors: [String]) {
        self.cwd = cwd
        self.entries = entries
        self.errors = errors
    }
}
