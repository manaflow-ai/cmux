import Combine
import CmuxWorkspaces
import Foundation

/// App-target `SelectedWorkspaceReading` adapter feeding the package
/// `SelectedWorkspaceDirectoryModel` through the `AsyncStream` seam.
///
/// **Modernization status.** The selection side is fully on `@Observable`
/// observation: `WorkspacesModel.observeSelectedTabId` drives re-pointing,
/// replacing the retired `selectedTabIdPublisher` Combine bridge. The inner
/// per-workspace directory/remote fan-in (`Workspace.$currentDirectory` and the
/// four `$remote*` properties) is the one remaining Combine `.sink`: those are
/// `@Published` on `Workspace`, which is still an `ObservableObject`, so
/// `withObservationTracking` cannot watch them. This bridge is load-bearing —
/// without it the file explorer would stop following a `cd` while the same
/// workspace stays selected — and is removable only once `Workspace` migrates
/// to `@Observable` in its own (out-of-scope, behavior-affecting) PR. It is
/// re-pointed on each selected-workspace-id change, hand-rolling the former
/// `switchToLatest`.
///
/// **Dedup ownership.** Per the `SelectedWorkspaceReading` contract, this
/// conformer forwards every upstream snapshot verbatim; the model is the single
/// writer of `directoryChangeGeneration` and the single place that
/// deduplicates (the legacy pipeline's trailing `removeDuplicates()`). The
/// adapter therefore keeps no `lastSnapshot` of its own.
@MainActor
final class SelectedWorkspaceDirectoryReadingAdapter: SelectedWorkspaceReading {
    let directorySnapshots: AsyncStream<SelectedWorkspaceDirectorySnapshot>
    private let continuation: AsyncStream<SelectedWorkspaceDirectorySnapshot>.Continuation
    private weak var tabManager: TabManager?
    private var selectionObservation: WorkspacesObservation?
    private var trackedSelectedWorkspaceId: UUID??
    private var innerCancellable: AnyCancellable?

    init() {
        (directorySnapshots, continuation) = AsyncStream.makeStream(
            of: SelectedWorkspaceDirectorySnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    func wire(tabManager: TabManager) {
        guard self.tabManager !== tabManager || selectionObservation == nil else { return }
        self.tabManager = tabManager
        trackedSelectedWorkspaceId = nil
        selectionObservation = tabManager.workspaces.observeSelectedTabId { [weak self] in
            self?.repointSelectedWorkspace()
        }
        // `selectedTabIdPublisher` replayed its current value on subscribe;
        // observation does not, so resolve the initial selection now.
        repointSelectedWorkspace()
    }

    /// Hand-rolls the former `selectedTabIdPublisher`→workspace→`combineLatest`
    /// `switchToLatest` chain. Resolves the selected workspace (nil when none is
    /// selected, like the former non-compacting `map`), and when the selected id
    /// changes (the former `removeDuplicates(by: id)`, nil included) re-points the
    /// inner subscription. A nil selection yields `.none`; a non-nil selection
    /// subscribes to the workspace's directory/remote `combineLatest`. Each
    /// snapshot is forwarded verbatim; the model owns deduplication.
    private func repointSelectedWorkspace() {
        guard let tabManager else { return }
        let selectedId = tabManager.selectedTabId
        let workspace = selectedId.flatMap { id in tabManager.tabs.first(where: { $0.id == id }) }
        let workspaceId = workspace?.id
        // `removeDuplicates(by: { $0?.id == $1?.id })`: only re-point when the
        // resolved workspace identity changes (nil↔non-nil or a different id).
        if let tracked = trackedSelectedWorkspaceId, tracked == workspaceId { return }
        trackedSelectedWorkspaceId = .some(workspaceId)
        innerCancellable?.cancel()
        guard let workspace else {
            // `Just(.none)` branch.
            continuation.yield(.none)
            return
        }
        innerCancellable = workspace.currentDirectoryPublisher
            .combineLatest(
                workspace.remoteConfigurationPublisher,
                workspace.remoteConnectionStatePublisher,
                workspace.remoteConnectionDetailPublisher
            )
            .combineLatest(workspace.remoteDaemonStatusPublisher)
            .map { values, remoteDaemonStatus in
                let (
                    currentDirectory,
                    remoteConfiguration,
                    remoteConnectionState,
                    remoteConnectionDetail
                ) = values
                return SelectedWorkspaceDirectorySnapshot(
                    workspaceId: workspace.id,
                    currentDirectory: currentDirectory,
                    remoteConfiguration: remoteConfiguration,
                    remoteConnectionState: remoteConnectionState,
                    remoteConnectionDetail: remoteConnectionDetail,
                    remoteDaemonStatus: remoteDaemonStatus
                )
            }
            .sink { [weak self] snapshot in
                self?.continuation.yield(snapshot)
            }
    }

    deinit {
        continuation.finish()
    }
}
