import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct MainWindowBootstrapView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(WindowAccessor { window in
                window.identifier = NSUserInterfaceItemIdentifier("cmux.bootstrap")
                window.isRestorable = false
                window.orderOut(nil)
                Task { @MainActor [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
            })
    }
}


let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    "cmux.settings",
    "cmux.about",
    "cmux.licenses",
    "cmux.browser-popup",
    "cmux.browserProfilePopoverDebug",
    "cmux.configEditor",
    "cmux.feedButtonStyleDebug",
    "cmux.feedPreview",
    "cmux.feedTextEditorDebug",
    "cmux.fileExplorerStyleDebug",
    "cmux.folderDragIcon",
    "cmux.pdfPreviewChromeDebug",
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
]

/// Returns whether the given window should handle the standard close shortcut
/// as a standalone auxiliary window instead of routing it through workspace or
/// panel-close behavior.
func cmuxWindowShouldOwnCloseShortcut(_ window: NSWindow?) -> Bool {
    guard let identifier = window?.identifier?.rawValue else { return false }
    return cmuxAuxiliaryWindowIdentifiers.contains(identifier)
}
