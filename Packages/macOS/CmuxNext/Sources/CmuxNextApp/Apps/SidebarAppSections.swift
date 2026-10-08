import AppKit
import CmuxNextApps
import CmuxNextSidebar

/// One window's app sections for its sidebar: the platform's
/// `AppSectionProvider` and the optional native Chats section. Per window,
/// because a view has one superview; mounts of the same app share its engine.
@MainActor
final class SidebarAppSections: SidebarAppSectionProvider {
    private let provider: AppSectionProvider
    private var chats: AgentRecentsSection?
    private(set) var showsChats: Bool
    private var contentChange: (() -> Void)?

    init(registry: AppRegistry, host: AppHost, recents: AgentRecentsSection?, showsChats: Bool) {
        provider = AppSectionProvider(registry: registry, host: host)
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

    func title(for contribution: String) -> String? {
        contribution == SidebarChatsView.contribution ? SidebarChatsView.title : provider.title(for: contribution)
    }

    func makeView(for contribution: String) -> NSView? {
        contribution == SidebarChatsView.contribution ? chats?.contentView : provider.makeView(for: contribution)
    }

    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        guard contribution != SidebarChatsView.contribution else { return chats?.height ?? 0 }
        return provider.preferredHeight(for: contribution, width: width)
    }
}
