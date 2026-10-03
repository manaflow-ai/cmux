/// What Cmd-W (and every close action) means in a window.
public nonisolated enum WindowCloseSemantics: Equatable, Sendable {
    /// Close the focused content first (a main window: its focused tab).
    case contentFirst
    /// Close the window (`performClose`, so its delegate may decline, as
    /// with the close button).
    case window
}

/// The background a window of a kind gets from ``NSWindow/install(kind:content:scope:)``.
public nonisolated enum WindowSurface: Equatable, Sendable {
    /// The one surface token (``ThemeTokens/surfaceBackground``) of the
    /// window's theme scope, opaque: a window of its own has no material
    /// behind it, and a see-through Settings window was hard to read. The
    /// main window's root paints the token over its material itself
    /// (``WindowSurfacePainting``).
    case token
    /// Clear: the content draws its own surface (onboarding glass).
    case clear
    /// The content view paints the window background itself, the token
    /// over the window's material (the main window's root,
    /// ``WindowSurfacePainting``).
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
