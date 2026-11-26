#if canImport(AppKit)

public import AppKit

/// A complete, editable description of the titlebar treatment applied to an
/// About-family window by the About Titlebar Debug subsystem.
///
/// When ``overridesEnabled`` is `false`, the store falls back to ``defaults(for:)``
/// so the window keeps its normal appearance; the remaining fields only take
/// effect once overrides are enabled.
public struct AboutTitlebarDebugOptions: Equatable, Sendable {
    /// Whether the debug overrides in this value are applied at all.
    public var overridesEnabled: Bool
    /// The window title text (trimmed; empty falls back to the kind's title).
    public var windowTitle: String
    /// Whether the title text is shown or hidden.
    public var titleVisibility: TitlebarVisibilityOption
    /// Whether the titlebar background is transparent.
    public var titlebarAppearsTransparent: Bool
    /// Whether the window is draggable by its background.
    public var movableByWindowBackground: Bool
    /// Whether the `.titled` style-mask bit is set.
    public var titled: Bool
    /// Whether the `.closable` style-mask bit is set.
    public var closable: Bool
    /// Whether the `.miniaturizable` style-mask bit is set.
    public var miniaturizable: Bool
    /// Whether the `.resizable` style-mask bit is set.
    public var resizable: Bool
    /// Whether the `.fullSizeContentView` style-mask bit is set.
    public var fullSizeContentView: Bool
    /// Whether a toolbar is attached to the window.
    public var showToolbar: Bool
    /// The toolbar style applied when ``showToolbar`` is `true`.
    public var toolbarStyle: TitlebarToolbarStyleOption

    /// Creates an options value with every field specified.
    public init(
        overridesEnabled: Bool,
        windowTitle: String,
        titleVisibility: TitlebarVisibilityOption,
        titlebarAppearsTransparent: Bool,
        movableByWindowBackground: Bool,
        titled: Bool,
        closable: Bool,
        miniaturizable: Bool,
        resizable: Bool,
        fullSizeContentView: Bool,
        showToolbar: Bool,
        toolbarStyle: TitlebarToolbarStyleOption
    ) {
        self.overridesEnabled = overridesEnabled
        self.windowTitle = windowTitle
        self.titleVisibility = titleVisibility
        self.titlebarAppearsTransparent = titlebarAppearsTransparent
        self.movableByWindowBackground = movableByWindowBackground
        self.titled = titled
        self.closable = closable
        self.miniaturizable = miniaturizable
        self.resizable = resizable
        self.fullSizeContentView = fullSizeContentView
        self.showToolbar = showToolbar
        self.toolbarStyle = toolbarStyle
    }

    /// The default, non-overriding options for a given window kind. This matches
    /// the window's normal appearance, so applying it with overrides disabled is
    /// a no-op relative to the system defaults.
    public static func defaults(for kind: AboutWindowKind) -> AboutTitlebarDebugOptions {
        switch kind {
        case .about:
            return AboutTitlebarDebugOptions(
                overridesEnabled: false,
                windowTitle: "About cmux",
                titleVisibility: .hidden,
                titlebarAppearsTransparent: true,
                movableByWindowBackground: false,
                titled: true,
                closable: true,
                miniaturizable: true,
                resizable: false,
                fullSizeContentView: false,
                showToolbar: false,
                toolbarStyle: .automatic
            )
        }
    }
}

#endif
