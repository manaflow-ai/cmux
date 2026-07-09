import Foundation

/// The app-typed per-window UI-state slices a main-window registration carries
/// across the ``WindowLifecycleHosting`` seam.
///
/// `WindowLifecycleCoordinator.registerMainWindow` owns the window-identity
/// decision but cannot name these app-declared `@MainActor` model types, so it
/// forwards this value opaquely (as `Host.RegistrationSlices`) from the
/// registration entrypoint into the host seed/rebind callbacks; only the
/// app-side host unpacks its fields. A plain value type holding the model
/// references: it never crosses an isolation boundary (the coordinator and the
/// host are both `@MainActor`), so it needs no `Sendable`.
struct MainWindowRegistrationSlices {
    /// The window's sidebar state, seeded into the sidebar store for a new window.
    let sidebarState: SidebarState

    /// The window's sidebar selection state, seeded for a new window.
    let sidebarSelectionState: SidebarSelectionState

    /// The window's optional file-explorer state. When present it seeds (or
    /// re-seeds) the file-explorer store and feeds the focus-controller update.
    let fileExplorerState: FileExplorerState?

    /// The window's optional cmux-config store, seeded when present.
    let cmuxConfigStore: CmuxConfigStore?
}
