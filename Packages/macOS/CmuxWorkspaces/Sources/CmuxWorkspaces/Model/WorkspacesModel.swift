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
        didSet { unobservedTabsSnapshot = tabs }
    }

    /// Current workspace order without registering an Observation dependency.
    ///
    /// Composition owners that bridge this model through another observation
    /// system use this snapshot to avoid accidentally observing both layers.
    @ObservationIgnored
    public private(set) var unobservedTabsSnapshot: [Tab] = []

    /// Named groupings of workspaces shown as collapsible sections in the
    /// sidebar. Group order in this array defines section order. Each member
    /// workspace stores its `groupId` on the workspace itself.
    public var workspaceGroups: [WorkspaceGroup] = [] {
        willSet {
            groupNamesByAnchorWorkspaceId = Dictionary(
                newValue.map { ($0.anchorWorkspaceId, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            host?.workspaceGroupsWillChange(to: newValue)
        }
        didSet { unobservedWorkspaceGroupsSnapshot = workspaceGroups }
    }

    /// Current workspace groups without registering an Observation dependency.
    @ObservationIgnored
    public private(set) var unobservedWorkspaceGroupsSnapshot: [WorkspaceGroup] = []

    /// O(1) display-title lookup for group anchors in title-churn observers.
    @ObservationIgnored
    public private(set) var groupNamesByAnchorWorkspaceId: [UUID: String] = [:]

    /// The selected workspace's id, if any.
    public var selectedTabId: UUID? {
        willSet { host?.selectedWorkspaceIdWillChange(to: newValue) }
        didSet {
            unobservedSelectedTabIdSnapshot = selectedTabId
            host?.selectedWorkspaceIdDidChange(from: oldValue)
        }
    }

    /// Current selection without registering an Observation dependency.
    @ObservationIgnored
    public private(set) var unobservedSelectedTabIdSnapshot: UUID?

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
