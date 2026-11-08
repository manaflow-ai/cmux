public import CmuxNextLayout

/// One window's frame as the window dock sees it (plans/cmux-next/docked-workspace-DESIGN.md): its docks, the
/// workspace with the focus, the stage, and the few window operations a dock change needs. The App's
/// `WindowController` conforms with one-line forwards; the dock operations themselves are this package's
/// (`WindowDockFrame+Operations`), so a test can drive them with a fake frame.
@MainActor
public protocol WindowDockFrame: AnyObject {
    /// The window record id.
    var frameWindowID: String { get }
    /// The window's docks (`WindowState.docks`).
    var frameDocks: WindowDocks { get set }
    /// `WorkspaceModel.id` of the workspace with the focus (`WindowState.workspaceID`).
    var frameFocusedWorkspaceID: String? { get }
    /// The workspace the stage shows (`WindowState.stageWorkspaceID`).
    var frameStageWorkspaceID: String? { get set }
    /// The workspace whose content fills the stage now (the window's `content`), docked or not.
    var frameShownWorkspaceID: String? { get }
    /// The workspaces this window lists.
    var frameMembers: [String] { get }
    /// `WorkspaceModel.id` of the window's Home, when it has one (classic Home has none).
    var frameHome: String? { get }
    /// The window's Chief panel (`WindowState.chiefPanel`), persisted in the window record.
    var frameChiefPanel: ChiefPanel { get set }
    /// Until this instant, the next workspace shown gets the floating Chief (a link from the Chief). In memory only.
    var frameChiefPanelArm: ContinuousClock.Instant? { get set }
    /// The Chief panel draws now.
    var frameChiefPanelShown: Bool { get }
    /// The keyboard is in the Chief panel.
    var frameChiefPanelHasKeys: Bool { get }
    /// Whether the shown Chief panel lies that way from the stage (``ChiefPanelView/lies(toward:docked:)``).
    func frameChiefPanelLies(toward direction: LayoutDirection) -> Bool
    /// The Chief panel's message box takes the keys.
    func frameFocusChiefPanel()
    /// The stage takes the keys: its pane nearest the panel when `direction` says where from, else its focused one.
    func frameFocusStage(toward direction: LayoutDirection?)
    /// Places the changed Chief panel now and saves the window record on settle.
    func frameChiefPanelDidChange()
    /// Shows workspace `id` in this window; `thisWindow` keeps it here even when another window lists it.
    func frameShow(_ id: String, thisWindow: Bool)
    /// Opens a new workspace in this window (in `cwd`, or the focused workspace's directory); its id, nil on failure.
    func frameCreateWorkspace(cwd: String?) async -> String?
    /// Docks workspace `id` at `edge` once the daemon reports it (a workspace made for an empty edge).
    func frameDockWhenReported(_ id: String, at edge: DockEdge)
    /// Lists workspace `id` in this window without selecting it.
    func frameClaim(_ id: String)
    /// Places the changed frame now and saves the window record on settle.
    func frameDidChange()
    /// Saves the window record on settle, with no new placement (a change only the panes read).
    func frameSaveRecord()
}
