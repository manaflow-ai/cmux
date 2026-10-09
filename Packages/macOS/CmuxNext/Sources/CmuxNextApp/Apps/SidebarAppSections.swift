import AppKit
import CmuxNextApps
import CmuxNextSidebar

/// One window's app sections for its sidebar: the platform's
/// `AppSectionProvider` and the optional native Chats section. Per window,
/// because a view has one superview; every mount streams from the app
/// supervisor, which runs one host per app.
@MainActor
final class SidebarAppSections: SidebarAppSectionProvider {
    private let provider: AppSectionProvider
    private var chats: AgentRecentsSection?
    private(set) var showsChats: Bool
    private var contentChange: (() -> Void)?

    init(apps: AppsService, recents: AgentRecentsSection?, showsChats: Bool) {
        provider = AppSectionProvider(client: apps.client) { [weak apps] in apps?.presence.isPresented($0) == true }
        chats = showsChats ? recents : nil
        self.showsChats = showsChats
        chats?.onContentChange = { [weak self] in self?.contentChange?() }
    }

    /// Updates visibility without creating a feed consumer while Chats is off.
    func setChats(_ section: AgentRecentsSection?, visible: Bool) {
        guard visible != showsChats || (visible && chats == nil) else { return }
        showsChats = visible
        chats = visible ? section : nil
        chats?.onContentChange = { [weak self] in self?.contentChange?() }
        contentChange?()
    }

    var onContentChange: (() -> Void)? {
        get { contentChange }
        set {
            contentChange = newValue
            provider.onContentChange = newValue
            chats?.onContentChange = { [weak self] in self?.contentChange?() }
        }
    }

    /// All chats draws its own hover-revealed header (`SidebarChatsView`), so the band adds no title row.
    func title(for contribution: String) -> String? {
        contribution == SidebarChatsView.contribution ? nil : provider.title(for: contribution)
    }

    func makeView(for contribution: String) -> NSView? {
        contribution == SidebarChatsView.contribution ? chats?.contentView : provider.makeView(for: contribution)
    }

    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        guard contribution != SidebarChatsView.contribution else { return chats?.height ?? 0 }
        return provider.preferredHeight(for: contribution, width: width)
    }
}
