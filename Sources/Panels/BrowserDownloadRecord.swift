import Foundation

/// Immutable snapshot of a single browser download, surfaced in the
/// Safari/Chrome-style downloads popover. Value type so it can be passed below
/// the popover's `ForEach` boundary without dragging the `BrowserPanel` store
/// along (see the snapshot-boundary rule in CLAUDE.md).
struct BrowserDownloadRecord: Identifiable, Equatable {
    enum State: Equatable {
        case downloading
        case saved
        case failed
    }

    /// Stable id — the download's `download_id` from the event stream.
    let id: String
    var filename: String
    /// Final on-disk location once `state == .saved`.
    var fileURL: URL?
    var state: State
    /// File size in bytes once known (saved downloads only).
    var byteCount: Int?

    var isComplete: Bool { state != .downloading }
}
