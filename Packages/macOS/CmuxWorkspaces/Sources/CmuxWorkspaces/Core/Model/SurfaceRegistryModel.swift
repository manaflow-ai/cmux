public import Foundation
public import Observation

/// The per-workspace surface-registry sub-model: owns the per-surface
/// registry annotations and the transient tab-selection/focus-reassert
/// requests the legacy `Workspace` god object kept as loose stored
/// properties (`surfaceTTYNames`, `panelShellActivityStates`,
/// `pendingTabSelection`, `isApplyingTabSelection`,
/// `pendingNonFocusSplitFocusReassert`,
/// `nonFocusSplitFocusReassertGeneration`).
///
/// The surface-id-to-panel-id mapping itself lives in the pane-tree
/// sub-model (`CmuxPanes.PaneTreeModel`), which owns the Bonsplit edge; this
/// model owns the registry state keyed by the workspace-side panel/surface
/// UUIDs and is Bonsplit-free.
///
/// `TabSelectionRequest` is the window's pending tab-selection request type
/// (the app target's `Workspace.PendingTabSelectionRequest`, which carries
/// AppKit hosted-view references and therefore stays app-side). None of the
/// stored properties used the old Combine-backed observation path on the legacy god object, so this
/// storage move carries no observer-parity hooks: no whole-object invalidation
/// emission existed to preserve.
@MainActor
@Observable
public final class SurfaceRegistryModel<TabSelectionRequest> {
    /// The coalesced pending tab-selection request; the workspace drains this
    /// in its re-entrancy-guarded apply loop (legacy
    /// `Workspace.pendingTabSelection`).
    public var pendingTabSelection: TabSelectionRequest?

    /// Re-entrancy guard for the tab-selection apply loop (legacy
    /// `Workspace.isApplyingTabSelection`).
    public var isApplyingTabSelection = false

    /// The pending non-focusing-split focus re-assert request, if any (legacy
    /// `Workspace.pendingNonFocusSplitFocusReassert`).
    public var pendingNonFocusSplitFocusReassert: PendingNonFocusSplitFocusReassert?

    /// Monotonic generation counter for focus re-assert requests; the
    /// workspace wraps with `&+= 1` on each new request (legacy
    /// `Workspace.nonFocusSplitFocusReassertGeneration`).
    public var nonFocusSplitFocusReassertGeneration: UInt64 = 0

    /// The controlling-terminal device name reported for each surface, keyed
    /// by panel id (legacy `Workspace.surfaceTTYNames`).
    public var surfaceTTYNames: [UUID: String] = [:]

    /// The shell-activity classification reported for each terminal panel,
    /// keyed by panel id (legacy `Workspace.panelShellActivityStates`).
    public var panelShellActivityStates: [UUID: PanelShellActivityState] = [:]

    /// Creates an empty registry; the owning workspace populates it as
    /// surfaces register.
    public init() {}
}
