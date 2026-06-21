public import Foundation

/// The window-side seam `WorkspacesModel` drives when its selection state
/// changes. The per-window `TabManager` is the single implementer.
///
/// **Why synchronous hooks and not an AsyncStream.** The selection hooks run
/// in the same MainActor turn as the assignment: the `willSet` hook fires
/// while `selectedTabId` still holds its old value (the host's DEBUG
/// workspace-switch tracing reads it there), and the `didSet` hook runs the
/// legacy selection side effects synchronously — including re-entrant
/// mutations (group auto-expand, focus-history recording) whose interleaving
/// is part of the observable selection contract. A stream would open a
/// suspension window between the mutation and its side effects.
///
/// The `tabs` / `workspaceGroups` `objectWillChange`-re-emission hooks were
/// retired when `TabManager` became `@Observable`: SwiftUI observers now track
/// the `@Observable` `WorkspacesModel` (through `TabManager`'s forwarders)
/// directly, so no host re-emission is needed for those collections.
///
/// Parity contract: the selection hooks fire on **every** assignment,
/// including assignments of an equal value. Guards that skip work for no-op
/// assignments live in the host's hook bodies, exactly where the legacy
/// property-observer guards sat.
@MainActor
public protocol WorkspacesHosting<Tab>: AnyObject {
    /// The window's workspace ("tab") type; the app target's `Workspace`.
    associatedtype Tab: WorkspaceTabRepresenting

    /// The selected workspace id is about to change (legacy `@Published
    /// selectedTabId` willSet; the host's DEBUG switch tracing lives here).
    func selectedWorkspaceIdWillChange(to newValue: UUID?)
    /// The selected workspace id changed (legacy `@Published selectedTabId`
    /// didSet; the host runs the legacy selection side effects).
    func selectedWorkspaceIdDidChange(from oldValue: UUID?)
}
