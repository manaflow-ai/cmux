#if canImport(UIKit)
/// Single-writer result box for synchronous debug snapshot collection.
///
/// Safety: each box is written by exactly one surface executor closure before
/// that closure leaves the dispatch group. The synchronous reader only reads
/// boxes after the group wait succeeds. On timeout, the function returns without
/// reading any boxes, and any late writer owns only its private box.
final class VisibleTerminalSnapshotResultBox: @unchecked Sendable {
    var section: String?
}
#endif
