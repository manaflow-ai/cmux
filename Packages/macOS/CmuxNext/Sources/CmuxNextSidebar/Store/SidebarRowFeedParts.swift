import Foundation
import Observation

/// One row's observation in a `SidebarRowFeed`: maps the row under tracking and calls back once, on the
/// row's next change. ``cancel()`` fires (and so removes) the armed observation: observation tracking
/// has no cancel call.
@Observable
final class SidebarRowWatch {
    private var epoch: UInt64 = 0

    /// `make()` under an observation that calls `changed(onMain)` on its next change: at once when the
    /// write was on the main thread (`onMain` true), else on a main-actor task.
    @MainActor func track(_ make: () -> SidebarWorkspace,
                          changed: @escaping @MainActor @Sendable (_ onMain: Bool) -> Void) -> SidebarWorkspace {
        // view-observation-allow: SidebarRowFeed is the rows' observation primitive (p06 task 329 allow-list): one tracking per watched row, flushed by the feed's caused schedule
        withObservationTracking {
            _ = epoch
            return make()
        } onChange: {
            if Thread.isMainThread {
                MainActor.assumeIsolated { changed(true) } // main-proof: checked on the line above
            } else {
                // task-owner: the row feed; one re-map of this row after an off-main write
                // main-hop-allow: the primitive's one hop for an off-main will-set (no main turn to run in); the re-map it marks flushes on the feed's caused schedule
                Task { @MainActor in changed(false) }
            }
        }
    }

    func cancel() { epoch &+= 1 }
}

extension SidebarRowFeed {
    /// What a list shows of the rows it draws (``watch(drawn:_:)``): on screen, near (on screen and its
    /// overscan), and the members of the open groups whose header is on screen (the header rolls up
    /// their state).
    public nonisolated struct Viewport: Equatable, Sendable {
        public var visible: Set<WorkspaceID>
        public var near: Set<WorkspaceID>
        public var rollUp: Set<WorkspaceID>

        /// `near` always holds `visible`.
        public init(visible: Set<WorkspaceID> = [], near: Set<WorkspaceID> = [], rollUp: Set<WorkspaceID> = []) {
            self.visible = visible
            self.near = near.union(visible)
            self.rollUp = rollUp
        }

        /// The rows whose place differs between `self` and `other`. O(rows near), and O(roll-up members) only
        /// when the headers on screen changed (the list hands the same roll-up set while they stay).
        func moved(from other: Viewport) -> Set<WorkspaceID> {
            var moved = visible.symmetricDifference(other.visible).union(near.symmetricDifference(other.near))
            if rollUp != other.rollUp { moved.formUnion(rollUp.symmetricDifference(other.rollUp)) }
            return moved
        }
    }

    /// What a row's observation does on its next change.
    enum WatchState {
        /// No observation: the row may be stale (it changed since its last map, or the pass's inputs did).
        case stale
        /// Marks the row dirty, and a flush maps it.
        case armed
        /// Only marks the row `stale`: the row is off screen.
        case sentinel
    }

    /// How current a row is kept.
    enum Level {
        /// Mapped on each change.
        case armed
        /// In the overscan: mapped once when it comes there stale, then a sentinel.
        case followed
        /// Off screen, a member of an open group whose header is on screen: a sentinel whose change maps the
        /// row once in the budgeted automation lane, behind every other row, so the header's roll-up catches up.
        case rolledUp
        /// Off screen and its overscan: a sentinel, then stale after its next change.
        case away
    }
}

/// One cause's dirty rows of a ``SidebarRowFeed``, in marking order, and its scheduled flushes: each
/// flush takes up to its slice of rows, and a mark that finds no room left in the scheduled ones
/// asks for one more.
struct SidebarRowLane {
    private var ids: [WorkspaceID] = []
    private var head = 0
    /// Rows the scheduled flushes can still take before another must be scheduled.
    private var room = 0
    /// Flushes scheduled and not run yet.
    private var scheduled = 0

    /// Adds `id`; true when the caller must schedule a flush for it.
    mutating func add(_ id: WorkspaceID, rowsPerFlush: Int) -> Bool {
        ids.append(id)
        let needsFlush = room == 0
        if needsFlush {
            room = rowsPerFlush
            scheduled += 1
        }
        room -= 1
        return needsFlush
    }

    /// One scheduled flush runs: the next `limit` rows still marked by this lane's cause (`isMarked`).
    mutating func take(_ limit: Int, isMarked: (WorkspaceID) -> Bool) -> [WorkspaceID] {
        scheduled = max(0, scheduled - 1)
        if scheduled == 0 { room = 0 }
        var taken: [WorkspaceID] = []
        while head < ids.count, taken.count < limit {
            let id = ids[head]
            head += 1
            if isMarked(id) { taken.append(id) }
        }
        if head == ids.count {
            ids.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= ids.count {
            ids.removeFirst(head)
            head = 0
        }
        return taken
    }

    /// Forgets the rows (the feed reset); flushes already scheduled still run and find none.
    mutating func dropRows() {
        ids.removeAll()
        head = 0
    }
}
