public import Foundation

/// Sequences every workstream flow over the window's `WorkspacesModel`:
/// create / rename / delete, member add/remove, reorder, and drill-in
/// navigation (enter / exit).
///
/// Unlike `WorkspaceGroupCoordinator`, this coordinator needs no window-side
/// host: a workstream is a pure container whose mutations are entirely
/// expressible on the model (set `Workstream` entries + flip each member
/// workspace's `workstreamId`). That keeps it trivially unit-testable and free
/// of focus side effects, which matters for the socket/CLI paths that must not
/// steal the user's active workspace (the socket focus policy in CLAUDE.md).
@MainActor
public final class WorkstreamCoordinator<Tab: WorkspaceTabRepresenting> {
    private let model: WorkspacesModel<Tab>

    /// Default auto-name format used when no localized format is supplied.
    /// The app overrides this with a `String(localized:)` format; this English
    /// fallback only applies to non-localized callers (tests, raw socket).
    public static var defaultAutoNameFormat: String { "Workstream %lld" }

    /// Creates the coordinator over the window's workspace model.
    public init(model: WorkspacesModel<Tab>) {
        self.model = model
    }

    // MARK: - Creation

    /// Create a new workstream and (optionally) move the given workspaces into
    /// it. A blank `name` falls back to the next "Workstream N" auto-name.
    /// Returns the new workstream's id.
    ///
    /// Membership is exclusive: any listed workspace already in another
    /// workstream is reassigned into the new one (a workspace is in at most one
    /// workstream), mirroring how moving a tab between groups works.
    @discardableResult
    public func createWorkstream(
        name: String,
        memberWorkspaceIds: [UUID] = [],
        autoNameFormat: String? = nil
    ) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmed.isEmpty
            ? nextAutoWorkstreamName(format: autoNameFormat ?? Self.defaultAutoNameFormat)
            : trimmed
        let workstream = Workstream(id: UUID(), name: resolvedName)
        model.workstreams.append(workstream)
        let memberSet = Set(memberWorkspaceIds)
        for tab in model.tabs where memberSet.contains(tab.id) {
            tab.workstreamId = workstream.id
        }
        // The `workstreams` append above already invalidates observers, but the
        // member reassignments don't on their own — note them so the count is
        // correct even if append observation is coalesced.
        if !memberSet.isEmpty {
            model.noteWorkstreamMembershipChanged()
        }
        return workstream.id
    }

    // MARK: - Properties

    /// Rename a workstream. Whitespace-only names are ignored.
    public func renameWorkstream(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = model.workstreams.firstIndex(where: { $0.id == id }) else { return }
        guard model.workstreams[index].name != trimmed else { return }
        model.workstreams[index].name = trimmed
    }

    /// Set the workstream's color override (hex string, nil clears).
    public func setWorkstreamColor(id: UUID, hex: String?) {
        guard let index = model.workstreams.firstIndex(where: { $0.id == id }) else { return }
        guard model.workstreams[index].customColor != hex else { return }
        model.workstreams[index].customColor = hex
    }

    /// Set the workstream's row icon (SF Symbol name, nil clears to default).
    public func setWorkstreamIcon(id: UUID, symbol: String?) {
        guard let index = model.workstreams.firstIndex(where: { $0.id == id }) else { return }
        guard model.workstreams[index].iconSymbol != symbol else { return }
        model.workstreams[index].iconSymbol = symbol
    }

    // MARK: - Deletion

    /// Delete a workstream. Member workspaces are NOT closed — they become
    /// top-level (workstream-less) workspaces again, exactly like ungrouping a
    /// `WorkspaceGroup` keeps its members. If the deleted workstream was the
    /// one currently drilled into, navigation falls back to the top level.
    /// Returns the number of workspaces released from the workstream.
    @discardableResult
    public func deleteWorkstream(id: UUID) -> Int {
        guard model.workstreams.contains(where: { $0.id == id }) else { return 0 }
        var released = 0
        for tab in model.tabs where tab.workstreamId == id {
            tab.workstreamId = nil
            released += 1
        }
        model.workstreams.removeAll { $0.id == id }
        if model.drilledInWorkstreamId == id {
            model.drilledInWorkstreamId = nil
        }
        if released > 0 {
            model.noteWorkstreamMembershipChanged()
        }
        return released
    }

    // MARK: - Membership

    /// Move an existing workspace into a workstream (reassigning it out of any
    /// other workstream it was in). No-op if the target workstream or the
    /// workspace does not exist.
    public func addWorkspaceToWorkstream(workspaceId: UUID, workstreamId: UUID) {
        guard model.workstreams.contains(where: { $0.id == workstreamId }) else { return }
        guard let tab = model.tabs.first(where: { $0.id == workspaceId }) else { return }
        guard tab.workstreamId != workstreamId else { return }
        tab.workstreamId = workstreamId
        model.noteWorkstreamMembershipChanged()
    }

    /// Remove a workspace from its workstream, returning it to the top level.
    /// No-op if the workspace is not in any workstream.
    public func removeWorkspaceFromWorkstream(workspaceId: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == workspaceId }),
              tab.workstreamId != nil else { return }
        tab.workstreamId = nil
        model.noteWorkstreamMembershipChanged()
    }

    // MARK: - Ordering

    /// Final index for a relative ("before"/"after" a peer) move, compensating
    /// for removing the source first: when the source sits before the peer,
    /// removing it shifts the peer left by one. Pure + static so it is unit
    /// testable without a live model. Returns the `toIndex` to pass to
    /// `moveWorkstream(id:toIndex:)`.
    public static func relativeMoveTargetIndex(currentIndex: Int, peerIndex: Int, after: Bool) -> Int {
        guard currentIndex != peerIndex else { return currentIndex }
        let peerPost = currentIndex < peerIndex ? peerIndex - 1 : peerIndex
        return after ? peerPost + 1 : peerPost
    }

    /// Move a workstream to a new position in the master list. `targetIndex`
    /// is the final index the workstream should occupy, clamped to the array
    /// bounds.
    public func moveWorkstream(id: UUID, toIndex targetIndex: Int) {
        guard let currentIndex = model.workstreams.firstIndex(where: { $0.id == id }) else { return }
        let clamped = max(0, min(targetIndex, model.workstreams.count - 1))
        guard clamped != currentIndex else { return }
        let workstream = model.workstreams.remove(at: currentIndex)
        model.workstreams.insert(workstream, at: clamped)
    }

    // MARK: - Drill-in navigation

    /// Drill into a workstream: the sidebar switches to showing only that
    /// workstream's workspaces. Does NOT change the focused workspace (the
    /// terminal area keeps showing whatever was selected); navigation is a
    /// view concern only. No-op for an unknown id.
    public func enterWorkstream(id: UUID) {
        guard model.workstreams.contains(where: { $0.id == id }) else { return }
        guard model.drilledInWorkstreamId != id else { return }
        model.drilledInWorkstreamId = id
    }

    /// Return to the top-level workstream list.
    public func exitWorkstreamDrillIn() {
        guard model.drilledInWorkstreamId != nil else { return }
        model.drilledInWorkstreamId = nil
    }

    // MARK: - Helpers

    /// Pick the next "Workstream N" name that doesn't collide with an existing
    /// workstream name. `format` is a `String.localizedStringWithFormat`
    /// template with a single `%lld`.
    public func nextAutoWorkstreamName(format: String) -> String {
        let used = Set(model.workstreams.map(\.name))
        var n = model.workstreams.count + 1
        while true {
            let candidate = String.localizedStringWithFormat(format, n)
            if !used.contains(candidate) { return candidate }
            n += 1
        }
    }
}
