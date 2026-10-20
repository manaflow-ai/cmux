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
///
/// Reads and writes are tracked through a non-generic
/// `WorkspacesModelObservation` rather than `@Observable`, which would key
/// them by generic key paths the runtime rebuilds on every read (#15439).
/// The accessors below do what the Swift 6.2 `@Observable` expansion does:
/// `tabs` notifies on every assignment, since `Tab` has no equality, while
/// `workspaceGroups` and `selectedTabId` notify only when the value changes.
/// Every assignment still runs the host hooks.
@MainActor
public final class WorkspacesModel<Tab: WorkspaceTabRepresenting>: Observable {
    /// The window's workspaces in sidebar order.
    public var tabs: [Tab] {
        get {
            observation.access(\.tabs)
            return storedTabs
        }
        set {
            observation.withMutation(of: \.tabs) { storedTabs = newValue }
        }
    }

    /// The window's workspaces keyed by id, for lookups that would otherwise
    /// scan `tabs`. Rebuilt before the host's tabs hook runs, so the host
    /// and its bridge subscribers see the incoming list. Reading it isn't
    /// tracked; use `tab(id:)` where a view must update when `tabs` changes.
    public private(set) var tabsById: [UUID: Tab] = [:]

    /// Named groupings of workspaces shown as collapsible sections in the
    /// sidebar. Group order in this array defines section order. Each member
    /// workspace stores its `groupId` on the workspace itself.
    public var workspaceGroups: [WorkspaceGroup] {
        get {
            observation.access(\.workspaceGroups)
            return storedWorkspaceGroups
        }
        set {
            guard newValue != storedWorkspaceGroups else {
                storedWorkspaceGroups = newValue
                return
            }
            observation.withMutation(of: \.workspaceGroups) { storedWorkspaceGroups = newValue }
        }
    }

    /// O(1) display-title lookup for group anchors in title-churn observers.
    public private(set) var groupNamesByAnchorWorkspaceId: [UUID: String] = [:]

    /// The selected workspace's id, if any.
    public var selectedTabId: UUID? {
        get {
            observation.access(\.selectedTabId)
            return storedSelectedTabId
        }
        set {
            guard newValue != storedSelectedTabId else {
                storedSelectedTabId = newValue
                return
            }
            observation.withMutation(of: \.selectedTabId) { storedSelectedTabId = newValue }
        }
    }

    private let observation = WorkspacesModelObservation()

    private var storedTabs: [Tab] = [] {
        willSet {
            tabsById = Dictionary(
                newValue.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            host?.workspaceTabsWillChange(to: newValue)
        }
    }

    private var storedWorkspaceGroups: [WorkspaceGroup] = [] {
        willSet {
            groupNamesByAnchorWorkspaceId = Dictionary(
                newValue.map { ($0.anchorWorkspaceId, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            host?.workspaceGroupsWillChange(to: newValue)
        }
    }

    private var storedSelectedTabId: UUID? {
        willSet { host?.selectedWorkspaceIdWillChange(to: newValue) }
        didSet { host?.selectedWorkspaceIdDidChange(from: oldValue) }
    }

    private weak var host: (any WorkspacesHosting<Tab>)?

    /// Creates an empty model; the owning window attaches itself as host
    /// before the first mutation.
    public init() {}

    /// The workspace with `id`, looked up in `tabsById`. Tracked as a read of
    /// `tabs`, so an observing view updates exactly when a `tabs` read would.
    public func tab(id: UUID) -> Tab? {
        observation.access(\.tabs)
        return tabsById[id]
    }

    /// Attaches the window-side host. Must be called before the first
    /// mutation so the property-observer hooks match the legacy `@Published`
    /// timing from the very first workspace insertion.
    public func attach(host: any WorkspacesHosting<Tab>) {
        self.host = host
    }
}
