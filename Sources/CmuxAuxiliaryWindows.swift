import AppKit

/// Identifiers of standalone auxiliary windows (settings, about, debug
/// windows, the pairing window, …). A window carrying one of these handles
/// the standard close shortcut itself instead of routing it through
/// workspace/panel close behavior. Extracted from `cmuxApp.swift` so the
/// roster can grow without growing that file.
private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
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
    "cmux.spinnerGallery",
    "cmux.backgroundDebug",
    "cmux.startupAppearanceDebug",
    "cmux.bonsplitTabBarDebug",
    "cmux.titlebarLayoutDebug",
    "cmux.devWindowDisplay",
    "cmux.mobilePairingWindow",
]

/// Returns whether the given window should handle the standard close shortcut
/// as a standalone auxiliary window instead of routing it through workspace or
/// panel-close behavior.
func cmuxWindowShouldOwnCloseShortcut(_ window: NSWindow?) -> Bool {
    guard let identifier = window?.identifier?.rawValue else { return false }
    // Hive viewer windows carry a per-computer suffix, so match the prefix.
    if identifier.hasPrefix(HiveViewerWindowController.windowIdentifierPrefix) {
        return true
    }
    return cmuxAuxiliaryWindowIdentifiers.contains(identifier)
}
