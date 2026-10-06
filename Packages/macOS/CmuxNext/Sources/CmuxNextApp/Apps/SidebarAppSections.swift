import AppKit
import CmuxNextApps
import CmuxNextSidebar

/// One window's app sections for its sidebar: the platform's
/// `AppSectionProvider` behind the sidebar's protocol, and the native
/// Recents section. Per window, because a view has one superview; mounts of
/// the same app share its engine.
@MainActor
final class SidebarAppSections: SidebarAppSectionProvider {
    private let provider: AppSectionProvider
    private let recents: AgentRecentsSection?

    init(registry: AppRegistry, host: AppHost, recents: AgentRecentsSection?) {
        provider = AppSectionProvider(registry: registry, host: host)
        self.recents = recents
    }

    var onContentChange: (() -> Void)? {
        get { provider.onContentChange }
        set {
            provider.onContentChange = newValue
            recents?.onContentChange = newValue
        }
    }

    func title(for contribution: String) -> String? {
        contribution == SidebarRecentsView.contribution ? SidebarRecentsView.title : provider.title(for: contribution)
    }

    func makeView(for contribution: String) -> NSView? {
        contribution == SidebarRecentsView.contribution ? recents?.contentView : provider.makeView(for: contribution)
    }

    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        guard contribution != SidebarRecentsView.contribution else { return recents?.height ?? 0 }
        return provider.preferredHeight(for: contribution, width: width)
    }
}
