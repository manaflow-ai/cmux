public import CmuxSettings
public import Foundation

/// Decides when an automatic "move to top" may run for a workspace.
///
/// In ``WorkspaceAutoReorderMode/notifications`` mode a notification moves
/// its workspace immediately, as it always has. In
/// ``WorkspaceAutoReorderMode/agentActivity`` mode notifications and
/// meaningful agent transitions share one throttle so a burst of activity
/// moves a row at most once per cooldown:
///
/// - Pinned and selected workspaces never move; the user is already looking
///   at the selected one, and pinned rows keep their place.
/// - A workspace already first in its tier is left alone, and a deferred
///   request for it is dropped: one agent event that also notifies must not
///   produce a second, trailing move that lifts the row back over newer
///   activity or a manual drag.
/// - While the pointer is over the sidebar or a sidebar drag is running, the
///   move is deferred, never dropped, so rows do not jump under the cursor.
/// - A workspace that moved less than ``cooldown`` ago is deferred until the
///   cooldown ends. Deferred requests for one workspace coalesce into a
///   single pending move. A notification inside the cooldown is dropped
///   instead, since it restates activity that already moved the row.
///
/// ``drain(mode:now:context:)`` releases pending moves oldest first, so the
/// most recent activity ends up on top. The gate is a value type with no
/// clock or UI access; the caller supplies the time and each workspace's
/// context.
public struct WorkspaceActivityReorderGate: Sendable {
    /// What asked for the move.
    public enum Trigger: Sendable, Equatable {
        /// An admitted notification for the workspace.
        case notification
        /// A meaningful agent lifecycle transition in the workspace.
        case agentActivity
    }

    /// The workspace's state at decision time.
    public struct Context: Sendable, Equatable {
        /// The workspace is pinned.
        public var isPinned: Bool
        /// The workspace is the selected one in its window.
        public var isSelected: Bool
        /// The workspace already sits first in its pin tier, so a move would
        /// change nothing now and a deferred one could only undo later order.
        public var isAtTop: Bool
        /// The pointer is over the sidebar, or a sidebar drag is running.
        public var isSidebarInteracting: Bool

        /// Creates a context.
        public init(isPinned: Bool, isSelected: Bool, isAtTop: Bool = false, isSidebarInteracting: Bool) {
            self.isPinned = isPinned
            self.isSelected = isSelected
            self.isAtTop = isAtTop
            self.isSidebarInteracting = isSidebarInteracting
        }
    }

    /// What the caller should do with one request.
    public enum Decision: Sendable, Equatable {
        /// Do nothing.
        case ignore
        /// Move the workspace to the top now.
        case moveNow
        /// Keep the request; ``drain(mode:now:context:)`` releases it later.
        case deferred
    }

    /// Default minimum interval between two activity moves of one workspace.
    public static let defaultCooldown: TimeInterval = 10

    /// Minimum interval between two activity moves of one workspace.
    public let cooldown: TimeInterval

    private var lastMoveAt: [UUID: Date] = [:]
    private var pendingSince: [UUID: Date] = [:]

    /// Creates a gate.
    ///
    /// - Parameter cooldown: Minimum interval between two activity moves of
    ///   one workspace.
    public init(cooldown: TimeInterval = Self.defaultCooldown) {
        self.cooldown = cooldown
    }

    /// Workspaces with a deferred move.
    public var pendingWorkspaceIds: Set<UUID> { Set(pendingSince.keys) }

    /// Decides one request.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace that saw the activity.
    ///   - trigger: What asked for the move.
    ///   - mode: The current reorder setting.
    ///   - context: The workspace's state now.
    ///   - now: The current time.
    /// - Returns: Whether to move now, defer, or ignore.
    public mutating func admit(
        workspaceId: UUID,
        trigger: Trigger,
        mode: WorkspaceAutoReorderMode,
        context: Context,
        now: Date
    ) -> Decision {
        switch mode {
        case .off:
            pendingSince.removeValue(forKey: workspaceId)
            return .ignore
        case .notifications:
            // The legacy mode is unchanged: notifications move immediately
            // (the notification path already keeps the focused pane's
            // workspace in place), agent transitions never move.
            pendingSince.removeValue(forKey: workspaceId)
            return trigger == .notification ? .moveNow : .ignore
        case .agentActivity:
            break
        }
        forgetExpiredMoves(now: now)
        guard !context.isPinned, !context.isSelected, !context.isAtTop else {
            pendingSince.removeValue(forKey: workspaceId)
            return .ignore
        }
        if trigger == .notification, isCoolingDown(workspaceId, now: now) {
            // The agent event behind this notification already moved the
            // row; deferring it would lift the row back over newer activity
            // once the cooldown ends. A pending activity move stays pending.
            return .ignore
        }
        if context.isSidebarInteracting || isCoolingDown(workspaceId, now: now) {
            pendingSince[workspaceId] = now
            return .deferred
        }
        pendingSince.removeValue(forKey: workspaceId)
        lastMoveAt[workspaceId] = now
        return .moveNow
    }

    /// Releases deferred moves that may run now.
    ///
    /// Requests whose workspace is gone, pinned, selected, or already on top
    /// are dropped.
    /// Requests still blocked by sidebar interaction or a cooldown stay
    /// pending.
    ///
    /// - Parameters:
    ///   - mode: The current reorder setting; anything but
    ///     ``WorkspaceAutoReorderMode/agentActivity`` drops every request.
    ///   - now: The current time.
    ///   - context: The context for a workspace, or `nil` when it is gone.
    /// - Returns: The workspaces to move, oldest request first, so moving
    ///   each to the top in order leaves the newest on top.
    public mutating func drain(
        mode: WorkspaceAutoReorderMode,
        now: Date,
        context: (UUID) -> Context?
    ) -> [UUID] {
        guard mode == .agentActivity else {
            pendingSince.removeAll()
            return []
        }
        forgetExpiredMoves(now: now)
        let ordered = pendingSince.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.uuidString < rhs.key.uuidString : lhs.value < rhs.value
        }
        var ready: [UUID] = []
        for (workspaceId, _) in ordered {
            guard let context = context(workspaceId), !context.isPinned, !context.isSelected, !context.isAtTop else {
                pendingSince.removeValue(forKey: workspaceId)
                continue
            }
            guard !context.isSidebarInteracting, !isCoolingDown(workspaceId, now: now) else { continue }
            pendingSince.removeValue(forKey: workspaceId)
            lastMoveAt[workspaceId] = now
            ready.append(workspaceId)
        }
        return ready
    }

    /// The earliest time after `now` at which a pending cooldown ends, or
    /// `nil` when no pending request waits on a cooldown.
    public func nextCooldownEnd(after now: Date) -> Date? {
        pendingSince.keys
            .compactMap { lastMoveAt[$0]?.addingTimeInterval(cooldown) }
            .filter { $0 > now }
            .min()
    }

    /// Drops all state for a workspace, for example after it closes.
    public mutating func forget(workspaceId: UUID) {
        lastMoveAt.removeValue(forKey: workspaceId)
        pendingSince.removeValue(forKey: workspaceId)
    }

    private func isCoolingDown(_ workspaceId: UUID, now: Date) -> Bool {
        guard let last = lastMoveAt[workspaceId] else { return false }
        return now < last.addingTimeInterval(cooldown)
    }

    /// Keeps memory bounded: a move older than the cooldown no longer
    /// affects any decision.
    private mutating func forgetExpiredMoves(now: Date) {
        lastMoveAt = lastMoveAt.filter { now < $0.value.addingTimeInterval(cooldown) }
    }
}
