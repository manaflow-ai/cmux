/// The set of standalone auxiliary cmux window identifiers and the rule for
/// whether such a window should own the standard close shortcut.
///
/// An auxiliary window (Settings, About, the browser popup, the various debug
/// inspectors, the mobile pairing window, etc.) does not host a terminal tab
/// manager, so when it is key it should handle `Cmd+W` by closing itself rather
/// than routing the shortcut through workspace- or panel-close behavior in a
/// main terminal window behind it.
///
/// This is a pure, immutable value: it holds only a frozen `Set<String>` of
/// window-identifier raw values and answers membership queries. The shared
/// `default` is the production identifier set; it is a value constant (no runtime
/// state), so it does not violate the no-stateful-singleton rule. Callers pass
/// the candidate window's `identifier?.rawValue`, which keeps all AppKit/`NSWindow`
/// dependency at the call site and lets this type stay in the foundation leaf.
public struct AuxiliaryWindowRegistry: Sendable, Equatable {
    /// The raw values of the window identifiers treated as standalone auxiliary
    /// windows that own the close shortcut.
    public let identifiers: Set<String>

    /// Creates a registry over the given set of window-identifier raw values.
    /// - Parameter identifiers: The raw values of auxiliary window identifiers.
    public init(identifiers: Set<String>) {
        self.identifiers = identifiers
    }

    /// Returns whether a window with the given identifier raw value should handle
    /// the standard close shortcut as a standalone auxiliary window instead of
    /// routing it through workspace or panel-close behavior.
    /// - Parameter identifier: The window's `identifier?.rawValue`, or `nil` when
    ///   the window has no identifier.
    /// - Returns: `true` when the identifier names a registered auxiliary window.
    public func shouldOwnCloseShortcut(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifiers.contains(identifier)
    }

    /// The production registry of cmux auxiliary window identifiers.
    public static let `default` = AuxiliaryWindowRegistry(identifiers: [
        "cmux.settings",
        "cmux.about",
        "cmux.licenses",
        "cmux.browser-popup",
        "cmux.browserProfilePopoverDebug",
        "cmux.configEditor",
        "cmux.defaultTerminalRegistrationError",
        "cmux.feedButtonStyleDebug",
        "cmux.feedPreview",
        "cmux.feedTextEditorDebug",
        "cmux.fileExplorerStyleDebug",
        "cmux.folderDragIcon",
        "cmux.pdfPreviewChromeDebug",
        "cmux.proBadgeDebug",
        "cmux.recentlyClosedHistory",
        "cmux.splitButtonLayoutDebug",
        "cmux.tabBarBackdropLab",
        "cmux.taskManager",
        "cmux.aboutTitlebarDebug",
        "cmux.debugWindowControls",
        "cmux.browserImportHintDebug",
        "cmux.extensionSidebarInspector",
        "cmux.sidebarDebug",
        "cmux.menubarDebug",
        "cmux.backgroundDebug",
        "cmux.startupAppearanceDebug",
        "cmux.bonsplitTabBarDebug",
        "cmux.titlebarLayoutDebug",
        "cmux.devWindowDisplay",
        "cmux.mobilePairingWindow",
    ])
}
