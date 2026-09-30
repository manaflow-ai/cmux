import CmuxTerminalSizing
import Foundation
import Observation

/// The single Mac-side owner of shared-terminal sizing state and actions.
///
/// Hosts (local terminals) and relays (Cloud mirrors) ``publish(_:surfaceID:)``
/// snapshots and ``register(_:surfaceID:)`` a controller. Every entrypoint
/// (tab accessory, context menu, size panel, shortcut, command palette,
/// socket/CLI) calls the actions here, so they share one mutation path.
@MainActor
@Observable
public final class TerminalSharingStore {
    /// Published snapshots, keyed by terminal surface id.
    public private(set) var snapshots: [UUID: TerminalSharingSnapshot] = [:]

    @ObservationIgnored private var controllers: [UUID: WeakController] = [:]
    /// Called after a surface's snapshot changes or is removed.
    @ObservationIgnored public var onChange: ((UUID) -> Void)?

    /// Creates an empty store.
    public init() {}

    // MARK: Hosts and relays

    /// Registers the controller that executes actions for a surface.
    ///
    /// - Parameters:
    ///   - controller: the host or relay for the surface.
    ///   - surfaceID: the terminal surface id.
    public func register(_ controller: any TerminalSharingSurfaceControlling, surfaceID: UUID) {
        controllers[surfaceID] = WeakController(value: controller)
    }

    /// Removes a surface's controller and snapshot if `controller` still owns it.
    ///
    /// - Parameters:
    ///   - controller: the controller that registered.
    ///   - surfaceID: the terminal surface id.
    public func unregister(_ controller: any TerminalSharingSurfaceControlling, surfaceID: UUID) {
        guard controllers[surfaceID]?.value === controller else { return }
        controllers[surfaceID] = nil
        publish(nil, surfaceID: surfaceID)
    }

    /// Replaces or removes a surface's snapshot.
    ///
    /// - Parameters:
    ///   - snapshot: the new snapshot, or `nil` to remove it.
    ///   - surfaceID: the terminal surface id.
    public func publish(_ snapshot: TerminalSharingSnapshot?, surfaceID: UUID) {
        guard snapshots[surfaceID] != snapshot else { return }
        snapshots[surfaceID] = snapshot
        onChange?(surfaceID)
    }

    /// The snapshot of a surface.
    ///
    /// - Parameter surfaceID: the terminal surface id.
    /// - Returns: its snapshot, if any host or relay published one.
    public func snapshot(for surfaceID: UUID) -> TerminalSharingSnapshot? { snapshots[surfaceID] }

    // MARK: Actions

    /// Replaces the policy.
    @discardableResult
    public func setPolicy(_ policy: TerminalSizingPolicy, surfaceID: UUID) -> Bool {
        controller(surfaceID)?.sharingSetPolicy(policy) ?? false
    }

    /// Switches the mode, keeping the priority list and fixed grid.
    ///
    /// `fixed` without a fixed grid fixes the current grid.
    @discardableResult
    public func setMode(_ mode: TerminalSizingMode, surfaceID: UUID) -> Bool {
        guard let snapshot = snapshots[surfaceID] else { return false }
        let policy = snapshot.state.policy.withMode(mode, fallbackFixed: snapshot.state.size)
        guard policy != snapshot.state.policy else { return true }
        return setPolicy(policy, surfaceID: surfaceID)
    }

    /// Sets a fixed grid and switches to `fixed`.
    @discardableResult
    public func setFixedSize(_ size: TerminalGridSize, surfaceID: UUID) -> Bool {
        guard let snapshot = snapshots[surfaceID] else { return false }
        let current = snapshot.state.policy
        return setPolicy(TerminalSizingPolicy(mode: .fixed, priority: current.priority, fixed: size), surfaceID: surfaceID)
    }

    /// Replaces the priority order (priority keys, highest first).
    @discardableResult
    public func setPriority(_ keys: [String], surfaceID: UUID) -> Bool {
        guard let snapshot = snapshots[surfaceID] else { return false }
        let current = snapshot.state.policy
        return setPolicy(TerminalSizingPolicy(mode: current.mode, priority: keys, fixed: current.fixed), surfaceID: surfaceID)
    }

    /// Sets or clears one participant's counts override.
    @discardableResult
    public func setCountsOverride(_ value: Bool?, participantID: String, surfaceID: UUID) -> Bool {
        controller(surfaceID)?.sharingSetCountsOverride(participantID: participantID, value: value) ?? false
    }

    /// Toggles "Don't Resize from This Mac" for this view.
    @discardableResult
    public func toggleSelfCounts(surfaceID: UUID) -> Bool {
        guard let snapshot = snapshots[surfaceID], let me = snapshot.selfParticipant else { return false }
        let value: Bool? = me.counts ? false : nil
        return setCountsOverride(value, participantID: me.id, surfaceID: surfaceID)
    }

    /// Disconnects one participant.
    ///
    /// This Mac's own UI (`by == nil`) disconnects only other participants.
    /// Another participant asking through this Mac (a phone or a viewing Mac,
    /// which passes `by`) may also disconnect this Mac's own view; that
    /// detaches the view only, never the terminal or the relay connection.
    ///
    /// - Parameters:
    ///   - participantID: the participant to disconnect.
    ///   - surfaceID: the terminal surface id.
    ///   - by: who asked, when not this Mac (a phone using the size panel).
    @discardableResult
    public func disconnect(participantID: String, surfaceID: UUID, by: TerminalDetachActor? = nil) -> Bool {
        guard let snapshot = snapshots[surfaceID],
              by != nil || participantID != snapshot.selfParticipantID,
              snapshot.state.participant(participantID) != nil else { return false }
        return controller(surfaceID)?.sharingDisconnect(participantID: participantID, by: by) ?? false
    }

    /// Disconnects every participant except this view (tmux `detach-client -a`).
    ///
    /// - Returns: how many disconnects were accepted.
    @discardableResult
    public func disconnectOthers(surfaceID: UUID) -> Int {
        guard let snapshot = snapshots[surfaceID] else { return 0 }
        return snapshot.otherParticipantIDs.reduce(0) { count, id in
            count + (disconnect(participantID: id, surfaceID: surfaceID) ? 1 : 0)
        }
    }

    /// Makes this view set the grid: adjusts the policy (see
    /// ``CmuxTerminalSizing/TerminalSizingPolicy/sizedTo(_:)``), clears an
    /// override that keeps this view from counting, and records activity.
    @discardableResult
    public func sizeToMe(surfaceID: UUID) -> Bool {
        guard let snapshot = snapshots[surfaceID],
              let me = snapshot.selfParticipant,
              let controller = controller(surfaceID) else { return false }
        let policy = snapshot.state.policy
            .migratingLegacyPriorityKeys(snapshot.state.participants.map(\.participant))
            .sizedTo(me.participant)
        if policy != snapshot.state.policy {
            guard controller.sharingSetPolicy(policy) else { return false }
        }
        if me.participant.countsOverride == false {
            _ = controller.sharingSetCountsOverride(participantID: me.id, value: nil)
        }
        controller.sharingNoteSelfActivity()
        return true
    }

    /// Reattaches this view after someone disconnected it.
    @discardableResult
    public func reattach(surfaceID: UUID, asViewer: Bool) -> Bool {
        controller(surfaceID)?.sharingReattach(asViewer: asViewer) ?? false
    }

    private func controller(_ surfaceID: UUID) -> (any TerminalSharingSurfaceControlling)? {
        guard let box = controllers[surfaceID] else { return nil }
        guard let value = box.value else {
            controllers[surfaceID] = nil
            return nil
        }
        return value
    }
}

/// A weak reference to a surface controller.
private struct WeakController {
    weak var value: (any TerminalSharingSurfaceControlling)?
}
