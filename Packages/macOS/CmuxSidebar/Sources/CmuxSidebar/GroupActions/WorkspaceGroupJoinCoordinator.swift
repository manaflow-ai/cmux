public import Foundation
public import CmuxSettings

/// Owns the in-flight "join the next async-created workspace to this group"
/// watchers for sidebar group `+` actions whose executor creates the workspace
/// asynchronously (cloudVM in particular launches `cmux vm new` and returns
/// immediately, before the workspace appears in the list).
///
/// This replaces the former `ConfiguredGroupActionAsyncWorkspaceObserver` static
/// `pending` registry that lived on the `AppDelegate` god object. The registry
/// is now instance state on a single coordinator constructed at the app
/// composition root and injected, so there is no process-wide singleton. One
/// watcher is kept per host (keyed by the host's `ObjectIdentifier`); a new
/// install for the same host disposes the previous one, matching the legacy
/// "one pending observer per `TabManager`" contract.
///
/// Each watcher subscribes to the host's workspace list via
/// ``WorkspaceGroupJoining/observeWorkspaceList(_:)`` and joins the first
/// previously-unknown workspace to the target group, then self-clears. It also
/// self-clears on group disappearance or a process-completion signal that names
/// the created workspace (``finishPending(host:observerId:workspaceId:)``) or
/// reports launch failure.
@MainActor
public final class WorkspaceGroupJoinCoordinator {
    private var pending: [ObjectIdentifier: Watcher] = [:]

    /// Creates an empty coordinator with no watch in flight.
    public init() {}

    /// Arms a watch on `host` that joins the next previously-unknown workspace
    /// to `groupId`. Replaces any existing watch for the same host. Returns the
    /// new watch's id so a later ``finishPending(host:observerId:workspaceId:)``
    /// / ``disposePending(host:observerId:)`` can target exactly this watch.
    @discardableResult
    public func install(
        host: any WorkspaceGroupJoining,
        groupId: UUID,
        knownIds: Set<UUID>,
        placement: WorkspaceGroupNewPlacement,
        referenceWorkspaceId: UUID?
    ) -> UUID {
        let key = ObjectIdentifier(host)
        pending[key]?.dispose()
        let watcher = Watcher(
            owner: self,
            host: host,
            key: key,
            groupId: groupId,
            placement: placement,
            referenceWorkspaceId: referenceWorkspaceId,
            knownIds: knownIds
        )
        pending[key] = watcher
        // Observe the host's `@Observable` workspace list instead of the retired
        // `tabsPublisher` Combine bridge. The watch fires on a MainActor hop
        // after each list mutation, reading the committed list — the same
        // post-change snapshot the old `.receive(on:).sink` saw. Observation
        // does not replay on subscribe, so scan the current list once now to
        // catch a workspace that already exists at install time (the bridge's
        // replay delivered this).
        watcher.startObserving()
        watcher.checkForNewWorkspace()
        return watcher.id
    }

    /// Cancels the pending watch for `host` if (and only if) it is the watch
    /// with `observerId`. A no-op once the watch has self-cleared or been
    /// superseded.
    public func disposePending(host: any WorkspaceGroupJoining, observerId: UUID) {
        let key = ObjectIdentifier(host)
        guard pending[key]?.id == observerId else { return }
        pending[key]?.dispose()
    }

    /// Resolves the pending watch for `host` with `observerId` using the exact
    /// created workspace id reported by a process completion. Joins it to the
    /// group if it is live, then disposes the watch. A no-op once the watch has
    /// self-cleared or been superseded.
    public func finishPending(
        host: any WorkspaceGroupJoining,
        observerId: UUID,
        workspaceId: UUID?
    ) {
        let key = ObjectIdentifier(host)
        guard let watcher = pending[key], watcher.id == observerId else { return }
        watcher.finish(workspaceId: workspaceId)
    }

    fileprivate func removeWatcher(forKey key: ObjectIdentifier) {
        pending.removeValue(forKey: key)
    }
}

extension WorkspaceGroupJoinCoordinator {
    /// One in-flight join watch. Holds the host weakly so a window that tears
    /// down mid-watch silently drops the join (the coordinator outlives the
    /// host either way).
    @MainActor
    fileprivate final class Watcher {
        let id = UUID()
        private weak var owner: WorkspaceGroupJoinCoordinator?
        private weak var host: (any WorkspaceGroupJoining)?
        private let key: ObjectIdentifier
        private let groupId: UUID
        private let placement: WorkspaceGroupNewPlacement
        private let referenceWorkspaceId: UUID?
        private var knownIds: Set<UUID>
        private var observation: (any WorkspaceGroupJoinObservation)?

        init(
            owner: WorkspaceGroupJoinCoordinator,
            host: any WorkspaceGroupJoining,
            key: ObjectIdentifier,
            groupId: UUID,
            placement: WorkspaceGroupNewPlacement,
            referenceWorkspaceId: UUID?,
            knownIds: Set<UUID>
        ) {
            self.owner = owner
            self.host = host
            self.key = key
            self.groupId = groupId
            self.placement = placement
            self.referenceWorkspaceId = referenceWorkspaceId
            self.knownIds = knownIds
        }

        func startObserving() {
            observation = host?.observeWorkspaceList { [weak self] in
                self?.checkForNewWorkspace()
            }
        }

        func checkForNewWorkspace() {
            guard let host else { dispose(); return }
            guard host.groupContainsLiveGroup(groupId) else {
                dispose()
                return
            }
            for id in host.currentWorkspaceIds() where !knownIds.contains(id) {
                host.addWorkspaceToGroup(
                    workspaceId: id,
                    groupId: groupId,
                    placement: placement,
                    referenceWorkspaceId: referenceWorkspaceId
                )
                dispose()
                return
            }
        }

        func finish(workspaceId: UUID?) {
            defer { dispose() }
            guard let workspaceId, let host else { return }
            guard host.groupContainsLiveGroup(groupId) else { return }
            guard host.containsWorkspace(workspaceId) else { return }
            host.addWorkspaceToGroup(
                workspaceId: workspaceId,
                groupId: groupId,
                placement: placement,
                referenceWorkspaceId: referenceWorkspaceId
            )
        }

        func dispose() {
            observation?.cancel()
            observation = nil
            // Remove by the key recorded at install time. The weak `host`
            // may already be nil here (window closed mid-watch), and walking it
            // would silently leak the entry in the `pending` dictionary for the
            // rest of the app session.
            owner?.removeWatcher(forKey: key)
        }
    }
}
