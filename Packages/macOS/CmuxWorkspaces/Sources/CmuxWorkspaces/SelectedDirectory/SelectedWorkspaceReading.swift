public import Foundation

/// The window-side read seam ``SelectedWorkspaceDirectoryModel`` consumes: a
/// single ``SelectedWorkspaceDirectorySnapshot`` stream that flattens the
/// selected workspace's directory and remote-connection state over time.
///
/// **Why an `AsyncStream` and not a synchronous two-way protocol.** Unlike the
/// focus-history and selection seams (which interleave reads and writes inside
/// one MainActor turn and therefore stay synchronous), this seam is
/// purely read-only change propagation: the legacy
/// `SelectedWorkspaceDirectoryObserver` was a Combine pipeline that fanned
/// `TabManager.selectedTabIdPublisher` into the selected `Workspace`'s five
/// `@Published` directory/remote properties via `combineLatest` +
/// `switchToLatest`, and emitted on each distinct value. The modern equivalent
/// of "a stream of values that switches source when the selection changes" is
/// an `AsyncStream` of snapshots. The model is the single writer of its
/// `directoryChangeGeneration`; it never writes back through this seam, so no
/// suspension-window hazard exists.
///
/// **Migration boundary (deliberate, documented).** The app-target adapter that
/// conforms this seam still bridges the legacy Combine publishers
/// (`selectedTabIdPublisher`, `Workspace.$currentDirectory`, etc.) into the
/// stream. Migrating `TabManager`/`Workspace` themselves off Combine is
/// deferred to those gods' own modernization PRs; this seam is the inversion
/// point that lets the model move now without waiting on them.
///
/// **Dedup ownership.** The stream may emit equal consecutive snapshots
/// (the adapter does not deduplicate). Deduplication — the legacy
/// `removeDuplicates()` that gated the generation bump — lives in the model,
/// the single place that decides whether the generation advances. Conformers
/// therefore forward every upstream emission verbatim.
public protocol SelectedWorkspaceReading: Sendable {
    /// A stream of directory/remote-state snapshots for the window's selected
    /// workspace, switching source whenever the selection changes. The stream
    /// replays the current snapshot to a new subscriber (matching the legacy
    /// `CurrentValueSubject` + `combineLatest` replay), so the model seeds its
    /// first generation bump from the first element exactly as the legacy
    /// `.sink` did.
    var directorySnapshots: AsyncStream<SelectedWorkspaceDirectorySnapshot> { get }
}
