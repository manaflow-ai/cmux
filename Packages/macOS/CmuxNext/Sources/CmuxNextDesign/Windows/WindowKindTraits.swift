/// What Cmd-W (and every close action) means in a window.
public nonisolated enum WindowCloseSemantics: Equatable, Sendable {
    /// Close the focused content first (a main window: its focused tab).
    case contentFirst
    /// Close the window (`performClose`, so its delegate may decline, as
    /// with the close button).
    case window
}

/// The background a window of a kind gets from ``NSWindow/install(kind:content:scope:)``.
/// Every kind has the one backdrop of the main window (the material and
/// the tint at the theme's opacity); only who draws it differs.
public nonisolated enum WindowSurface: Equatable, Sendable {
    /// The window kit wraps the content in a ``WindowSurfaceView`` that
    /// draws the backdrop under it.
    case backdrop
    /// The content view draws the backdrop itself (the main window's
    /// root, ``WindowSurfacePainting``).
    case content
}

/// The traits of a ``WindowKind``. Every kind is titled and closable: it
/// shows traffic lights with a close button.
public nonisolated struct WindowKindTraits: Equatable, Sendable {
    /// A cmux main window (sidebar, panes, workspaces).
    public var isMain: Bool
    public var close: WindowCloseSemantics
    public var surface: WindowSurface
    /// Only the close button shows (onboarding, popups).
    public var hidesMinimizeAndZoom: Bool
}
