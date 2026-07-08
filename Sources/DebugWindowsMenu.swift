import SwiftUI

#if DEBUG
/// The Debug > "Debug Windows" submenu, extracted from `cmuxApp.swift`
/// (see `AgentSessionDebugMenuButtons` / `CanvasDebugMenuButtons` for the
/// same pattern). Every item opens a singleton debug window controller.
struct DebugWindowsMenu: View {
    var body: some View {
        Menu("Debug Windows") {
            Button("Background Debug…") {
                BackgroundDebugWindowController.shared.show()
            }
            Button("Pro Badge Style…") {
                ProBadgeDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.bonsplitTabBarDebug",
                    defaultValue: "Bonsplit Tab Bar Debug…"
                )
            ) {
                BonsplitTabBarDebugWindowController.shared.show()
            }
            Button("Browser Import Hint Debug…") {
                BrowserImportHintDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.browserProfilePopoverDebug",
                    defaultValue: "Browser Profile Popover Debug…"
                )
            ) {
                BrowserProfilePopoverDebugWindowController.shared.show()
            }
            Button("Debug Window Controls…") {
                DebugWindowControlsWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.devWindowDisplay",
                    defaultValue: "Dev Window Display…"
                )
            ) {
                DevWindowDisplayDebugWindowController.shared.show()
            }
            Button("Feed Preview…") {
                FeedPreviewWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.feedTextEditorDebug",
                    defaultValue: "Feed Text Editor Lab…"
                )
            ) {
                FeedTextEditorDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.feedButtonStyleDebug",
                    defaultValue: "Feed Button Style Debug…"
                )
            ) {
                FeedButtonStyleDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.startupAppearanceDebug",
                    defaultValue: "Startup Appearance Debug…"
                )
            ) {
                StartupAppearanceDebugWindowController.shared.show()
            }
            Button("Menu Bar Extra Debug…") {
                MenuBarExtraDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.aboutTitlebarDebug",
                    defaultValue: "About Titlebar Debug…"
                )
            ) {
                AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
            }
            Button(
                String(
                    localized: "debug.menu.titlebarLayoutDebug",
                    defaultValue: "Titlebar Layout Debug..."
                )
            ) {
                TitlebarLayoutDebugWindowController.shared.show()
            }
            Button("Sidebar Debug…") {
                SidebarDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.splitButtonLayoutDebug",
                    defaultValue: "Split Button Layout Debug…"
                )
            ) {
                SplitButtonLayoutDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.tabBarBackdropLab",
                    defaultValue: "Tab Bar Backdrop Lab…"
                )
            ) {
                TabBarBackdropLabWindowController.shared.show()
            }
            Button("File Explorer Style Debug…") {
                FileExplorerStyleDebugWindowController.shared.show()
            }
            Button(
                String(
                    localized: "debug.menu.pdfPreviewChromeDebug",
                    defaultValue: "PDF Preview Chrome Debug…"
                )
            ) {
                PDFPreviewChromeDebugWindowController.shared.show()
            }
            Button("Open All Debug Windows") {
                Self.openAllDebugWindows()
            }
        }
    }

    private static func openAllDebugWindows() {
        DebugWindowControlsWindowController.shared.show()
        BrowserImportHintDebugWindowController.shared.show()
        BrowserProfilePopoverDebugWindowController.shared.show()
        AppDelegate.shared?.debugWindowsCoordinator.showAboutTitlebarDebugWindow()
        TitlebarLayoutDebugWindowController.shared.show()
        SidebarDebugWindowController.shared.show()
        BackgroundDebugWindowController.shared.show()
        StartupAppearanceDebugWindowController.shared.show()
        MenuBarExtraDebugWindowController.shared.show()
        PDFPreviewChromeDebugWindowController.shared.show()
        FeedPreviewWindowController.shared.show()
        FeedTextEditorDebugWindowController.shared.show()
        FeedButtonStyleDebugWindowController.shared.show()
        BonsplitTabBarDebugWindowController.shared.show()
        SplitButtonLayoutDebugWindowController.shared.show()
    }
}
#endif
