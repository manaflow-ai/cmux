import CmuxWindowing

/// Cross-window index of per-window ``WindowContext``s, keyed by ``WindowID``.
///
/// This replaces the six parallel `WindowScopedStore<…>` dictionaries
/// `AppDelegate` used to hold (`windowTabManagers`, `windowFocusControllers`,
/// `windowConfigStores`, `windowSidebarSelectionStates`, `windowSidebarStates`,
/// `windowFileExplorerStates`). The per-window state now lives in one
/// ``WindowContext`` per `NSWindow`; this registry is the single
/// `WindowID`→context index the window-lifecycle seam
/// (`resolveRegisteredWindow`, `seedNewMainWindowSlices`,
/// `rebindRegisteredWindowSlices`, `removeWindowModelSlices`, …) and the
/// per-window config/sidebar/file-explorer accessors resolve through.
///
/// The cross-window resolver family (`tabManagerFor`, `locateSurface`,
/// `workspaceContainingPanel`, `tabTitle`, `scriptableMainWindow`, …) is
/// unchanged: it iterates `registeredMainWindows` (which funnels through
/// `resolveRegisteredWindow`, now reading this registry) plus the
/// `recoverableMainWindowRoutes()` pass, exactly as before.
///
/// ## Ownership + teardown
///
/// The registry is the single strong owner of each ``WindowContext`` (exactly
/// replacing the dictionaries' strong ownership), so a context's lifetime
/// matches the old per-slice dictionary entries. It is a passive index: it does
/// NOT subscribe to `windowCoordinator.windowClosed` (a single-consumer stream
/// whose sole consumer is the window-teardown loop). Slice removal is driven by
/// that loop's single `removeWindowModelSlices` funnel calling
/// ``removeContext(for:)``.
///
/// ## Isolation
///
/// `@MainActor` because its mutators run on the main thread alongside window
/// registration and AppKit teardown. Internally it reuses the package's
/// ``WindowScopedStore`` (the canonical `WindowID`-keyed per-window store) as
/// its backing dictionary.
@MainActor
final class WindowRegistry {
    private let store = WindowScopedStore<WindowContext>()

    /// The context registered for `id`, or `nil` if no window has one.
    func context(for id: WindowID) -> WindowContext? {
        store.model(for: id)
    }

    /// Registers `context` for `id`, replacing any prior context for that window.
    func setContext(_ context: WindowContext, for id: WindowID) {
        store.setModel(context, for: id)
    }

    /// Removes and returns the context registered for `id`, if any. Called by the
    /// window-teardown funnel; idempotent if already gone.
    @discardableResult
    func removeContext(for id: WindowID) -> WindowContext? {
        store.remove(id)
    }

    /// The ``WindowID`` of every window that currently has a context, in no
    /// guaranteed order. Backs the coordinator's `registeredWindowIds`.
    var ids: [WindowID] {
        store.ids
    }

    /// Every registered context, in no guaranteed order. Mirrors the legacy
    /// aggregate-wide sweeps (e.g. reloading every window's config store).
    var contexts: [WindowContext] {
        store.models
    }
}
