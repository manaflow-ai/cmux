import AppKit
import CmuxAppKitSupportUI
import CmuxTerminal

/// Owns debug-window coordinators at the application composition root.
@MainActor
final class CmuxDebugWindowsCoordinator {
    private let aboutTitlebarCoordinator: DebugWindowsCoordinator
#if DEBUG
    private lazy var cloudAnnouncementPreviewController =
        CloudAnnouncementPreviewWindowController(decorator: decorator, defaults: .standard)
    private lazy var sidebarFooterIconBalanceController =
        SidebarFooterIconBalanceDebugWindowController(decorator: decorator)
#endif
    private weak var decorator: (any WindowDecorating)?

    init(decorator: (any WindowDecorating)?) {
        self.decorator = decorator
        self.aboutTitlebarCoordinator = DebugWindowsCoordinator(
            decorator: decorator,
            copyText: { text in
                _ = GhosttyApp.terminalPasteboard.writeString(
                    text,
                    to: .general
                )
            }
        )
    }

    var aboutTitlebarStore: AboutTitlebarDebugStore {
        aboutTitlebarCoordinator.aboutTitlebarStore
    }

    func showAboutTitlebarDebugWindow() {
        aboutTitlebarCoordinator.showAboutTitlebarDebugWindow()
    }

#if DEBUG
    func showCloudAnnouncementPreviewWindow() {
        cloudAnnouncementPreviewController.show()
    }

    func showSidebarFooterIconBalanceWindow() {
        sidebarFooterIconBalanceController.show()
    }
#endif
}

