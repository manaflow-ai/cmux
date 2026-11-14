public import CmuxNextActions
public import CmuxNextLayout

/// What the window dock's actions need from the app (plans/cmux-next/docked-workspace-DESIGN.md, user 2026-11-05):
/// the window an invocation targets, the Chief's Home and its settings, and the daemon tab moves of Move Pane to
/// Dock. The App conforms with one-line forwards (`AppServices+WindowDockHost`).
@MainActor
public protocol WindowDockHost: AnyObject {
    /// The window `invocation` targets (default: the active one); nil with no window open.
    func dockFrame(_ invocation: ActionInvocation) -> (any WindowDockFrame)?
    /// The active window; nil with none.
    var dockActiveFrame: (any WindowDockFrame)? { get }
    /// The open window that lists workspace `id`.
    func dockFrame(owning id: String) -> (any WindowDockFrame)?
    /// `WorkspaceModel.id` of the workspace `invocation` targets (default: the focused one).
    func dockTargetWorkspace(_ invocation: ActionInvocation) -> String?
    /// `WorkspaceModel.id` of the workspace that holds the pane `invocation` targets (default: the focused one).
    func dockPaneWorkspace(_ invocation: ActionInvocation) -> String?
    /// Moves every tab of the pane `invocation` targets, in order, into workspace `id`; false when one is gone.
    func dockMovePane(_ invocation: ActionInvocation, into id: String) -> Bool
    /// Moves every tab of the pane `invocation` targets, in order, into a new workspace; its id, nil on failure.
    func dockMovePaneToNewWorkspace(_ invocation: ActionInvocation) async -> String?
    /// The edge `home.chiefDock.edge` names (left when unset or unknown).
    var chiefDockEdge: DockEdge { get }
    /// Whether a link from the Chief docks it (`home.chiefDock.openBeside`, and Home is not classic).
    var chiefDockOpensBeside: Bool { get }
    /// Whether Home is classic (a top page, no Home workspace to dock).
    var chiefHomeIsClassic: Bool { get }
    /// `WorkspaceModel.id` of window `windowID`'s Home; nil when it has none yet.
    func chiefHome(in windowID: String) -> String?
    /// Makes window `windowID`'s Home (one daemon round trip); its id, nil on failure.
    func chiefMakeHome(in windowID: String) async -> String?
    /// Go to Home (classic Home's top page); false when refused.
    func chiefShowHome() -> Bool
    /// The docked Chief's message box takes the keys.
    func chiefFocusComposer()
    /// Brings cmux and its active window in front of the other apps; whether cmux was behind another app.
    func chiefBringAppForward() -> Bool
}
