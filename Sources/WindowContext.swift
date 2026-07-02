import AppKit
import CmuxWindowing

/// Per-window model + UI state for one main terminal `NSWindow`.
///
/// This consolidates the six per-window slices that previously lived in six
/// parallel `WindowScopedStore<…>` dictionaries on `AppDelegate`
/// (`windowTabManagers`, `windowFocusControllers`, `windowConfigStores`,
/// `windowSidebarSelectionStates`, `windowSidebarStates`,
/// `windowFileExplorerStates`) into one object owned per window. One
/// `WindowContext` exists per main `NSWindow`: it is built in the
/// window-registration funnel (`seedNewMainWindowSlices` / the DEBUG
/// `seedTestingMainWindowSlices`), indexed by ``WindowRegistry`` under the
/// window's ``WindowID``, held (weakly) by the per-window
/// `AppDelegate.MainWindowController`, and dropped by `removeWindowModelSlices`
/// on every window-teardown path.
///
/// The registry is the single strong owner of a context (exactly replacing the
/// dictionaries' strong ownership), so a context's lifetime matches the old
/// per-slice dictionary entries: it dies when the registry drops it on teardown.
/// The owning `MainWindowController` references its context weakly, purely to
/// express the per-window association without extending the context's lifetime.
///
/// ## Slice optionality
///
/// `tabManager`, `focusController`, `sidebarState`, and `sidebarSelectionState`
/// are always seeded together when the context is created, matching the old
/// invariant that a registered window always had those four slices.
/// `fileExplorerState` and `configStore` are optional by design: the lifted
/// `MainWindowContext.fileExplorerState` was a lazily-bound `var
/// FileExplorerState?` (nil until the window's content view seeds it) and the
/// config store may be absent, so an unset field reads back `nil` rather than a
/// synthesized empty default.
///
/// ## Isolation
///
/// `@MainActor` because every slice is a main-actor model mutated alongside
/// window registration and AppKit teardown, co-located with its callers so no
/// cross-actor hop is introduced.
@MainActor
final class WindowContext {
    /// The window this context belongs to.
    let windowId: WindowID

    /// The window's tab/workspace manager. Rebound by `rebindTabManagerSlice`
    /// during a same-window re-registration; never `nil` for a live context.
    var tabManager: TabManager

    /// The window's keyboard-focus / right-sidebar-mode controller. Its storage
    /// lives here, but the keyboard-focus accessor sites stay on `AppDelegate`
    /// (a `KeyEventRouter` concern for a later wave); they reach this through the
    /// resolved `RegisteredMainWindow.keyboardFocusCoordinator`.
    var focusController: MainWindowFocusController

    /// The window's sidebar visibility + persisted width state.
    var sidebarState: SidebarState

    /// The window's sidebar selection state.
    var sidebarSelectionState: SidebarSelectionState

    /// The window's right-sidebar (file-explorer) state, or `nil` until the
    /// content view lazily binds it. Optional by design; never seed an empty
    /// default (a missing value must read back `nil`).
    var fileExplorerState: FileExplorerState?

    /// The window's cmux-config store, or `nil` when the window has none.
    var configStore: CmuxConfigStore?

    init(
        windowId: WindowID,
        tabManager: TabManager,
        focusController: MainWindowFocusController,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState,
        fileExplorerState: FileExplorerState?,
        configStore: CmuxConfigStore?
    ) {
        self.windowId = windowId
        self.tabManager = tabManager
        self.focusController = focusController
        self.sidebarState = sidebarState
        self.sidebarSelectionState = sidebarSelectionState
        self.fileExplorerState = fileExplorerState
        self.configStore = configStore
    }
}
