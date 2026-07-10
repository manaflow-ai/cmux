public import Foundation

/// The window-side seam `WorkspacesModel` drives when its stored state
/// changes. The per-window `TabManager` is the single implementer.
///
/// **Why synchronous hooks and not an AsyncStream.** These hooks preserve the
/// pre-Observation Combine observer timing one-for-one: the `willSet` hooks
/// fire while the property still holds its old value, and the host re-emits
/// the compatibility bridge publishers at that same point. The selection
/// `didSet` hook runs the legacy selection side effects synchronously in the same MainActor turn —
/// including re-entrant mutations (group auto-expand, focus-history
/// recording) whose interleaving is part of the observable selection
/// contract. A stream would open a suspension window between the mutation
/// and its side effects.
///
/// Parity contract: hooks fire on **every** assignment, including
/// assignments of an equal value; the previous observer path never compared
/// assignments before notifying. Guards that skip work for no-op assignments
/// live in the host's hook bodies, exactly where the legacy property-observer
/// guards sat.
@MainActor
public protocol WorkspacesHosting<Tab>: AnyObject {
    /// The window's workspace ("tab") type; the app target's `Workspace`.
    associatedtype Tab: WorkspaceTabRepresenting

    /// The `tabs` array is about to change (legacy `tabs` willSet).
    func workspaceTabsWillChange(to newValue: [Tab])
    /// The `workspaceGroups` array is about to change (legacy `workspaceGroups` stored-property willSet).
    func workspaceGroupsWillChange(to newValue: [WorkspaceGroup])
    /// The selected workspace id is about to change (legacy `selectedTabId` stored-property willSet; the host's DEBUG switch tracing lives here).
    func selectedWorkspaceIdWillChange(to newValue: UUID?)
    /// The selected workspace id changed (legacy `selectedTabId`
    /// didSet; the host runs the legacy selection side effects).
    func selectedWorkspaceIdDidChange(from oldValue: UUID?)
}
