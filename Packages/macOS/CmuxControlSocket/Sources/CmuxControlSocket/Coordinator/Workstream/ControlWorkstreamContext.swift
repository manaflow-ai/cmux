public import Foundation

/// The workstream-domain slice of the control-command seam (a constituent of
/// the ``ControlCommandContext`` umbrella).
///
/// The app target (`TerminalController`) conforms by resolving a `TabManager`
/// from the routing selectors and reading/mutating its `Workstream`s through
/// `WorkstreamCoordinator`. No app types cross the seam: each method takes
/// pre-parsed selectors/ids and returns Sendable snapshots, resolution enums,
/// Bools, or Ints keyed by those ids. Every method is `@MainActor`.
@MainActor
public protocol ControlWorkstreamContext: AnyObject {
    /// Snapshots every workstream for `workstream.list`, with the owning window
    /// id and the currently drilled-into workstream id.
    func controlWorkstreamList(
        routing: ControlRoutingSelectors
    ) -> ControlWorkstreamListResolution

    /// Creates a workstream for `workstream.create`.
    ///
    /// - Parameters:
    ///   - routing: Routing selectors for TabManager resolution.
    ///   - name: The workstream name (already defaulted to "" when absent; the
    ///     app applies the localized "Workstream N" auto-name).
    ///   - workspaceIDs: Resolved member workspace ids, in request order.
    func controlCreateWorkstream(
        routing: ControlRoutingSelectors,
        name: String,
        workspaceIDs: [UUID]
    ) -> ControlWorkstreamCreateResolution

    /// Renames a workstream for `workstream.rename`. Returns `true` if it
    /// existed, `false` if not found, `nil` if no TabManager resolved.
    func controlRenameWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID,
        name: String
    ) -> Bool?

    /// Deletes a workstream for `workstream.delete` (members are kept, returned
    /// to the top level). Returns the count of released workspaces, `-1` if the
    /// workstream was not found, or `nil` if no TabManager resolved.
    func controlDeleteWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID
    ) -> Int?

    /// Moves a workspace into a workstream for `workstream.add`. Returns `true`
    /// if both resolved and the move happened, `false` if the workstream or
    /// workspace was not found, or `nil` if no TabManager resolved.
    func controlAddWorkspaceToWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID,
        workspaceID: UUID
    ) -> Bool?

    /// Removes a workspace from its workstream for `workstream.remove`. Returns
    /// `true` if it was in a workstream, `false` otherwise, or `nil` if no
    /// TabManager resolved.
    func controlRemoveWorkspaceFromWorkstream(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> Bool?

    /// Moves a workstream for `workstream.move`, resolving the target via an
    /// explicit `to_index` or a relative before/after peer. Returns `true` if it
    /// existed and a target resolved, `false` otherwise, or `nil` if no
    /// TabManager resolved.
    func controlMoveWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID,
        toIndex: Int?,
        beforeWorkstreamID: UUID?,
        afterWorkstreamID: UUID?
    ) -> Bool?

    /// Drills into a workstream for `workstream.enter` (view-state only; does
    /// not change the focused workspace). Returns `true` if it existed, `false`
    /// if not found, or `nil` if no TabManager resolved.
    func controlEnterWorkstream(
        routing: ControlRoutingSelectors,
        workstreamID: UUID
    ) -> Bool?

    /// Returns to the top-level workstream list for `workstream.exit`. Returns
    /// `true` on success, or `nil` if no TabManager resolved.
    func controlExitWorkstreamDrillIn(
        routing: ControlRoutingSelectors
    ) -> Bool?
}
