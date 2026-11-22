import AppKit
import CmuxNextActions

/// The sidebar profile menu (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2):
/// `sidebar.profileMenu` opens it over the active window's profile control
/// (the palette, `cmux action run sidebar.profileMenu` and the socket reach
/// the same menu a click opens), and `browser.downloads.showFolder` backs
/// its Downloads row.
enum ProfileMenuHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services
        registry.bind("sidebar.profileMenu", run: { _ in
            guard let sidebar = services.windows.active?.sidebar.container.sidebarView else {
                throw ActionFailure(message: RefusalStrings.noWindowOpen)
            }
            sidebar.showProfileMenu()
        })
        registry.bind("browser.downloads.showFolder", run: { _ in
            // Finder lists the folder; cmux itself reads nothing in it (LAUNCH-NO-TCC-PROMPTS).
            guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
            NSWorkspace.shared.open(folder)
        })
    }
}
