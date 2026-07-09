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
/// (objectWillChange re-emission, DEBUG switch tracing, and the selection
/// side-effect chain).
///
/// Being `@Observable`, this is the single observation source of truth:
/// external observers (sidebar, mobile sync, directory tracking, UI-test
/// recorders) track ``tabs`` / ``selectedTabId`` / ``workspaceGroups`` through
/// Observation — via ``observeTabs(_:)`` and its siblings, or SwiftUI
/// `.onChange` — instead of the retired `TabManager` `CurrentValueSubject`
/// bridges.
@MainActor
@Observable
public final class WorkspacesModel<Tab: WorkspaceTabRepresenting> {
    /// The window's workspaces in sidebar order. Pure `@Observable` storage:
    /// the host's legacy `objectWillChange`-re-emission willSet hook was retired
    /// when `TabManager` became `@Observable` (observers track this model
    /// directly through the `@Observable` chain).
    public var tabs: [Tab] = []

    /// Named groupings of workspaces shown as collapsible sections in the
    /// sidebar. Group order in this array defines section order. Each member
    /// workspace stores its `groupId` on the workspace itself. Pure
    /// `@Observable` storage (see ``tabs``).
    public var workspaceGroups: [WorkspaceGroup] = []

    /// The selected workspace's id, if any.
    public var selectedTabId: UUID? {
        willSet { host?.selectedWorkspaceIdWillChange(to: newValue) }
        didSet { host?.selectedWorkspaceIdDidChange(from: oldValue) }
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
