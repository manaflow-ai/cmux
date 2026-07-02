import AppKit
import CmuxSettings
import CmuxWindowing
import CmuxWorkspaces
import Foundation

/// The read-only app-level seam a `Workspace` reaches for the cross-window
/// services it does not own: notification state, the remote-tmux mirror
/// controller, tab-manager resolution, the focus log, and the two app-level
/// workspace-creation/move actions.
///
/// **Why this exists.** `Workspace` previously reached the running
/// `NSApplicationDelegate` directly through the `AppDelegate.shared` global at 40
/// call sites (notification store, `remoteTmuxController`, `tabManager` /
/// `tabManagerFor`, `focusLog`, `performCloudVMAction`,
/// `moveBonsplitTabToNewWorkspace`, and the command-palette-visibility window
/// lookups). That global coupling is the structural blocker to dropping
/// `Workspace`'s `ObservableObject` conformance and relocating the model into a
/// package: a model that names the app delegate cannot move below the app target,
/// and the singleton reach-up contradicts the de-singletonization and
/// per-window-ownership rulings.
///
/// This protocol inverts that coupling. `Workspace` holds an injected
/// `(any WorkspaceHostEnvironment)?` (constructor-injected at the composition
/// root, defaulting to `AppDelegate.shared`) and routes every former
/// `AppDelegate.shared?.X` through `self.hostEnvironment?.X`. The seam is
/// declared in the app target because every member it exposes returns an
/// app-target type (`TerminalNotificationStore`, `RemoteTmuxController`,
/// `TabManager`, `FocusLogStore`, `NSWindow`); per the executable-target
/// boundary rule, this live-state conformance stays in the app target while the
/// coupling itself is now an injectable seam rather than a hard global.
///
/// The seam is read-only and faithful: every accessor returns exactly what the
/// former `AppDelegate.shared?.X` returned, so optional-chaining behavior (a nil
/// `hostEnvironment` matching a nil `AppDelegate.shared`) is byte-identical.
@MainActor
protocol WorkspaceHostEnvironment: AnyObject {
    /// The process-lifetime app environment, used when a `Workspace` needs to
    /// reach router-owned active-window operations.
    var environment: AppEnvironment { get }

    /// The app's terminal-notification store (legacy
    /// `AppDelegate.shared?.notificationStore`). Optional because the store is a
    /// `weak` reference on the delegate that is only bound while a notification
    /// host is alive.
    var notificationStore: TerminalNotificationStore? { get }

    /// The remote-tmux mirror controller (legacy
    /// `AppDelegate.shared?.remoteTmuxController`). Non-optional on the delegate,
    /// so the optionality lives only on the host-environment reference.
    var remoteTmuxController: RemoteTmuxController { get }

    /// The app's currently bound tab manager (legacy
    /// `AppDelegate.shared?.tabManager`), used as the final resolution fallback
    /// when no per-tab manager is found.
    var tabManager: TabManager? { get }

    /// The DEBUG focus log (legacy `AppDelegate.shared?.focusLog`). Non-optional
    /// on the delegate; the optionality lives on the host-environment reference.
    var focusLog: FocusLogStore { get }

    /// The app's window registry, which owns cross-window resolver lookups.
    var windowRegistry: WindowRegistry { get }

    /// Resolves the tab manager owning the given workspace/tab id (legacy
    /// `AppDelegate.shared?.tabManagerFor(tabId:)`).
    func tabManagerFor(tabId: UUID) -> TabManager?

    /// The window id bound to the given tab manager (legacy
    /// `AppDelegate.shared?.windowId(for:)`).
    func windowId(for tabManager: TabManager) -> UUID?

    /// The main window for the given window id (legacy
    /// `AppDelegate.shared?.mainWindow(for:)`).
    func mainWindow(for windowId: UUID) -> NSWindow?

    /// Whether the command palette is visible in the given window (legacy
    /// `AppDelegate.shared?.isCommandPaletteVisible(for:)`).
    func isCommandPaletteVisible(for window: NSWindow) -> Bool

    /// Runs the app-level "create a Cloud VM workspace" action (legacy
    /// `AppDelegate.shared?.performCloudVMAction(...)`).
    @discardableResult
    func performCloudVMAction(
        tabManager preferredTabManager: TabManager?,
        preferredWindow: NSWindow?,
        debugSource: String,
        onCompletion: ((CloudVMActionCompletion) -> Void)?
    ) -> Bool

    /// Moves the bonsplit surface owning `tabId` into a brand-new workspace
    /// (legacy `AppDelegate.shared?.moveBonsplitTabToNewWorkspace(...)`).
    @discardableResult
    func moveBonsplitTabToNewWorkspace(
        tabId: UUID,
        destinationManager: TabManager?,
        title: String?,
        focus: Bool,
        focusWindow: Bool,
        placementOverride: WorkspacePlacement?,
        insertionIndexOverride: Int?
    ) -> SurfaceNewWorkspaceMoveResult?
}
