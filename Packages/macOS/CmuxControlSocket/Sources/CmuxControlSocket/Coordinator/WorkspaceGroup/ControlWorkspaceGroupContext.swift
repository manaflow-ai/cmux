public import Foundation

/// The workspace-group-domain slice of the control-command seam (a constituent
/// of the ``ControlCommandContext`` umbrella).
///
/// The app target (today `TerminalController`, the interim composition owner)
/// conforms by resolving a `TabManager` from the routing selectors (the legacy
/// `v2ResolveTabManager` precedence) and reading/mutating its `WorkspaceGroup`s.
/// Every method is `@MainActor` because its conformer and the coordinator both
/// live on the main actor, so these are plain in-isolation calls — the per-read
/// `v2MainSync` hops the legacy command bodies used disappear once the domain
/// moves onto the coordinator.
///
/// No app types (`TabManager` / `WorkspaceGroup` / `AppDelegate`) cross the
/// seam: each method takes pre-parsed selectors/ids and returns Sendable
/// snapshots, resolution enums, Bools, or optionals keyed by those ids. The two
/// localized error messages are supplied through ``ControlWorkspaceGroupStrings``
/// so they resolve against the app bundle.
@MainActor
public protocol ControlWorkspaceGroupContext: AnyObject {
    /// The localized workspace-group error messages, resolved against the app
    /// bundle so the coordinator can shape the two localized error envelopes
    /// (`allChildrenAreAnchors`, `workspaceIsOtherGroupAnchor`) without binding
    /// `String(localized:)` to the package bundle.
    func controlWorkspaceGroupStrings() -> ControlWorkspaceGroupStrings

    /// Snapshots every workspace group for `workspace.group.list`, with the
    /// owning window id (the coordinator mints the window/group refs).
    ///
    /// - Parameter routing: The routing selectors used for TabManager
    ///   resolution.
    /// - Returns: The list resolution.
    func controlWorkspaceGroupList(
        routing: ControlRoutingSelectors
    ) -> ControlWorkspaceGroupListResolution

    /// Creates a workspace group for `workspace.group.create`.
    ///
    /// The coordinator has already parsed `name` / `cwd`, resolved the child
    /// handles to UUIDs, and surfaced the param-shape `invalid_params` failures;
    /// this runs the live-state remainder (fallback child selection, the
    /// target-window existence check, the all-children-are-anchors guard, and
    /// the create call).
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution and the
    ///     caller-workspace fallback.
    ///   - name: The group name (already defaulted to "" when absent).
    ///   - cwd: The anchor working directory, if provided.
    ///   - childWorkspaceIDs: The resolved child workspace ids, in request order
    ///     (empty when none provided/resolved).
    ///   - childrenExplicit: Whether the caller explicitly listed
    ///     `child_workspace_ids` (drives the eligibility guard and disables the
    ///     fallback selection).
    /// - Returns: The create resolution.
    func controlCreateWorkspaceGroup(
        routing: ControlRoutingSelectors,
        name: String,
        cwd: String?,
        childWorkspaceIDs: [UUID],
        childrenExplicit: Bool
    ) -> ControlWorkspaceGroupCreateResolution

    /// Ungroups the group for `workspace.group.ungroup`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to ungroup.
    /// - Returns: `true` if the group existed and was ungrouped, `nil` if no
    ///   TabManager resolved.
    func controlUngroupWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Bool?

    /// Deletes the group for `workspace.group.delete`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to delete.
    /// - Returns: The number of workspaces closed if the group existed, `-1` if
    ///   the group was not found, or `nil` if no TabManager resolved.
    func controlDeleteWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> Int?

    /// Renames the group for `workspace.group.rename`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to rename.
    ///   - name: The new name.
    /// - Returns: `true` if the group existed and was renamed, `false` if not
    ///   found, or `nil` if no TabManager resolved.
    func controlRenameWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        name: String
    ) -> Bool?

    /// Sets the group's collapsed state for `workspace.group.collapse` /
    /// `workspace.group.expand`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to update.
    ///   - isCollapsed: The new collapsed state.
    /// - Returns: `true` if the group existed and was updated, `false` if not
    ///   found, or `nil` if no TabManager resolved.
    func controlSetWorkspaceGroupCollapsed(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        isCollapsed: Bool
    ) -> Bool?

    /// Sets the group's pinned state for `workspace.group.pin` /
    /// `workspace.group.unpin`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to update.
    ///   - isPinned: The new pinned state.
    /// - Returns: `true` if the group existed and was updated, `false` if not
    ///   found, or `nil` if no TabManager resolved.
    func controlSetWorkspaceGroupPinned(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        isPinned: Bool
    ) -> Bool?

    /// Adds a workspace to a group for `workspace.group.add`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The target group.
    ///   - workspaceID: The workspace to add.
    /// - Returns: The add resolution.
    func controlAddWorkspaceToGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID
    ) -> ControlWorkspaceGroupAddResolution

    /// Removes a workspace from its group for `workspace.group.remove`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - workspaceID: The workspace to remove.
    /// - Returns: `true` if the workspace was in a group and was removed,
    ///   `false` if not in a group, or `nil` if no TabManager resolved.
    func controlRemoveWorkspaceFromGroup(
        routing: ControlRoutingSelectors,
        workspaceID: UUID
    ) -> Bool?

    /// Sets the group's anchor workspace for `workspace.group.set_anchor`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to update.
    ///   - workspaceID: The member workspace to make the anchor.
    /// - Returns: `true` if the group existed and the workspace is a member,
    ///   `false` otherwise, or `nil` if no TabManager resolved.
    func controlSetWorkspaceGroupAnchor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        workspaceID: UUID
    ) -> Bool?

    /// Creates a new workspace in a group for `workspace.group.new_workspace`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The target group.
    ///   - placementRaw: The raw `placement` param (untrimmed), if present, so
    ///     the seam can do the single `WorkspaceGroupNewPlacement` parse and
    ///     resolve the per-cwd / global default.
    /// - Returns: The new-workspace resolution.
    func controlCreateWorkspaceInGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        placementRaw: String?
    ) -> ControlWorkspaceGroupNewWorkspaceResolution

    /// Sets the group's custom color for `workspace.group.set_color`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to update.
    ///   - hex: The normalized hex override, or `nil` to clear it.
    /// - Returns: `true` if the group existed and was updated, `false` if not
    ///   found, or `nil` if no TabManager resolved.
    func controlSetWorkspaceGroupColor(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        hex: String?
    ) -> Bool?

    /// Sets the group's custom icon for `workspace.group.set_icon`, returning the
    /// stored symbol the app actually persisted.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to update.
    ///   - symbol: The normalized symbol, or `nil` to clear it.
    /// - Returns: A pair of (`found`, `storedSymbol`) where `storedSymbol` is the
    ///   app-persisted symbol when found; `found` is `false` if the group was not
    ///   found; `nil` if no TabManager resolved.
    func controlSetWorkspaceGroupIcon(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        symbol: String?
    ) -> (found: Bool, storedSymbol: String?)?

    /// Moves a group for `workspace.group.move`, resolving the target via an
    /// explicit `to_index` or a relative `before_group_id` / `after_group_id`.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to move.
    ///   - toIndex: The explicit absolute target index, if provided.
    ///   - beforeGroupID: The peer to move before, if provided.
    ///   - afterGroupID: The peer to move after, if provided.
    /// - Returns: `true` if the group existed and a target resolved, `false`
    ///   otherwise, or `nil` if no TabManager resolved.
    func controlMoveWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID,
        toIndex: Int?,
        beforeGroupID: UUID?,
        afterGroupID: UUID?
    ) -> Bool?

    /// Focuses a group for `workspace.group.focus`: focuses the owning window,
    /// makes its TabManager active, and selects the group anchor.
    ///
    /// - Parameters:
    ///   - routing: The routing selectors used for TabManager resolution.
    ///   - groupID: The group to focus.
    /// - Returns: The focus resolution.
    func controlFocusWorkspaceGroup(
        routing: ControlRoutingSelectors,
        groupID: UUID
    ) -> ControlWorkspaceGroupFocusResolution
}
