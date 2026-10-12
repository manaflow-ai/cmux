import AppKit
import CmuxNextApps
import CmuxNextSidebar

/// One window's app sections for its sidebar: the platform's
/// `AppSectionProvider`. Per window, because a view has one superview; every
/// mount streams from the app supervisor, which runs one host per app. All
/// chats is not a sidebar section (Lawrence 2026-10-10): it lives on the New
/// Tab page (cx-n0i9).
@MainActor
final class SidebarAppSections: SidebarAppSectionProvider {
    private let provider: AppSectionProvider

    init(apps: AppsService) {
        provider = AppSectionProvider(client: apps.client) { [weak apps] in apps?.presence.isPresented($0) == true }
    }

    /// A section left the window's layout: its app mount ends on the supervisor.
    func release(_ contribution: String) {
        provider.release(contribution)
    }

    /// Unmounts every app section of this window on the supervisor.
    func releaseAll() {
        provider.releaseAll()
    }

    var onContentChange: (() -> Void)? {
        get { provider.onContentChange }
        set { provider.onContentChange = newValue }
    }

    func title(for contribution: String) -> String? {
        provider.title(for: contribution)
    }

    func makeView(for contribution: String) -> NSView? {
        provider.makeView(for: contribution)
    }

    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        provider.preferredHeight(for: contribution, width: width)
    }
}
