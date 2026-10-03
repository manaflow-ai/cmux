import AppKit
import CmuxNextApps
import CmuxNextSidebar

/// One window's app sections for its sidebar: the platform's
/// `AppSectionProvider` behind the sidebar's protocol. Per window, because a
/// view has one superview; mounts of the same app share its engine.
@MainActor
final class SidebarAppSections: SidebarAppSectionProvider {
    private let provider: AppSectionProvider

    init(registry: AppRegistry, host: AppHost) {
        provider = AppSectionProvider(registry: registry, host: host)
    }

    var onContentChange: (() -> Void)? {
        get { provider.onContentChange }
        set { provider.onContentChange = newValue }
    }

    func title(for contribution: String) -> String? { provider.title(for: contribution) }
    func makeView(for contribution: String) -> NSView? { provider.makeView(for: contribution) }
    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        provider.preferredHeight(for: contribution, width: width)
    }
}
