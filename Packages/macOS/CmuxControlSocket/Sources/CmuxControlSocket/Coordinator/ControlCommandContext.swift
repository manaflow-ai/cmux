/// The read-only seam through which ``ControlCommandCoordinator`` reaches live
/// app state to run control commands, without the package importing the app
/// target.
///
/// It is an umbrella of one protocol per command domain so the domains can be
/// built independently (each domain owns its own seam-protocol file and its own
/// app-conformance file). The coordinator stores `any ControlCommandContext`
/// and reaches every member through this inheritance. The app target (today
/// `TerminalController`, the interim composition owner; later
/// `TerminalControlComposition`) conforms by conforming to each constituent.
///
/// `AnyObject` so the coordinator can hold the conformer `weak` and avoid a
/// retain cycle with its composition owner.
@MainActor
public protocol ControlCommandContext:
    AnyObject,
    ControlWindowContext,
    ControlAppFocusContext,
    ControlFeedContext,
    ControlNotificationContext,
    ControlFleetContext,
    ControlWorkspaceGroupContext,
    ControlPaneContext,
    ControlCanvasContext,
    ControlMobileHostContext,
    ControlWorkspaceContext,
    ControlSurfaceContext,
    ControlSystemContext,
    ControlProjectContext,
    ControlDebugContext,
    ControlSidebarContext,
    ControlBrowserPanelContext
{}
