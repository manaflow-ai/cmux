public import Foundation
public import Observation

/// The per-window workspace-list sub-model: owns the window's workspace
/// ("tab") order, the sidebar group sections, and the selected-workspace id —
/// the stored state the legacy `TabManager` god object kept in its
/// `@Published tabs` / `workspaceGroups` / `selectedTabId` properties.
///
/// The window's `TabManager` composition root owns one instance, forwards
/// its legacy accessors here, and implements `WorkspacesHosting` to receive
/// the property-observer hooks the legacy `@Published` observers provided
/// (objectWillChange/bridge re-emission, DEBUG switch tracing, and the
/// selection side-effect chain).
@MainActor
@Observable
public final class WorkspacesModel<Tab: WorkspaceTabRepresenting> {
    /// The window's workspaces in sidebar order.
    public var tabs: [Tab] = [] {
        willSet { host?.workspaceTabsWillChange(to: newValue) }
    }

    /// Named groupings of workspaces shown as collapsible sections in the
    /// sidebar. Group order in this array defines section order. Each member
    /// workspace stores its `groupId` on the workspace itself.
    public var workspaceGroups: [WorkspaceGroup] = [] {
        willSet { host?.workspaceGroupsWillChange(to: newValue) }
    }

    /// The selected workspace's id, if any.
    public var selectedTabId: UUID? {
        willSet { host?.selectedWorkspaceIdWillChange(to: newValue) }
        didSet { host?.selectedWorkspaceIdDidChange(from: oldValue) }
    }

    /// Top-level drill-in "workstreams" shown as the sidebar's master view.
    /// Array order defines the order workstream rows appear in. Membership
    /// lives on each workspace's `workstreamId`. Mutated only through
    /// `WorkstreamCoordinator`.
    ///
    /// No host hook: unlike `tabs`/`workspaceGroups`/`selectedTabId` (whose
    /// hooks replay legacy `@Published` Combine bridges and the selection
    /// side-effect chain), workstream state is new and has no legacy bridge.
    /// `@Observable` drives the SwiftUI sidebar directly, and the periodic
    /// session autosave captures it for persistence.
    public var workstreams: [Workstream] = []

    /// The workstream the sidebar is currently drilled into, or `nil` for the
    /// top-level (master) view. When non-nil, the sidebar shows only that
    /// workstream's workspaces; when nil, it shows the workstream list plus
    /// every workspace not assigned to any workstream. This is the persisted
    /// "last-viewed" navigation state.
    public var drilledInWorkstreamId: UUID?

    /// Bumped whenever a workspace's `workstreamId` membership changes without
    /// the observed `tabs` / `workstreams` arrays themselves changing (i.e. the
    /// add/remove paths). The sidebar reads this so SwiftUI re-runs its body and
    /// recomputes the drill-in filter + rollups — `Workspace.workstreamId` is a
    /// Combine `@Published` on a reference element, which `@Observable` tracking
    /// of the model arrays does not see. Bump it via `noteWorkstreamMembershipChanged()`.
    public private(set) var workstreamMembershipRevision: Int = 0

    /// Signal that workstream membership changed; see `workstreamMembershipRevision`.
    public func noteWorkstreamMembershipChanged() {
        workstreamMembershipRevision &+= 1
    }

    @ObservationIgnored
    private weak var host: (any WorkspacesHosting<Tab>)?

    /// Creates an empty model; the owning window attaches itself as host
    /// before the first mutation.
    public init() {}

    /// Attaches the window-side host. Must be called before the first
    /// mutation so the property-observer hooks match the legacy `@Published`
    /// timing from the very first workspace insertion.
    public func attach(host: any WorkspacesHosting<Tab>) {
        self.host = host
    }
}
