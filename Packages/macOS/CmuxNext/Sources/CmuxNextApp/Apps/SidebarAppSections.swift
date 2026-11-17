import AppKit
import CmuxNextApps
import CmuxNextCloudUI
import CmuxNextSidebar

/// One window's app sections for its sidebar: the platform's
/// `AppSectionProvider`. Per window, because a view has one superview; every
/// mount streams from the app supervisor, which runs one host per app. All
/// chats is not a sidebar section (Lawrence 2026-10-10): it lives on the New
/// Tab page (cx-n0i9).
@MainActor
final class SidebarAppSections: SidebarAppSectionProvider {
    private let provider: AppSectionProvider
    /// The built-in Team section (``CloudTeamFeature/contribution``), drawn here, not by an app.
    private let team: (() -> CloudTeamHostingView?)?
    private var teamView: CloudTeamHostingView?

    init(apps: AppsService, team: (() -> CloudTeamHostingView?)? = nil) {
        provider = AppSectionProvider(client: apps.client) { [weak apps] in apps?.presence.isPresented($0) == true }
        self.team = team
    }

    /// A section left the window's layout: its app mount ends on the supervisor.
    func release(_ contribution: String) {
        if contribution == CloudTeamFeature.contribution { return teamView = nil }
        provider.release(contribution)
    }

    /// Unmounts every app section of this window on the supervisor.
    func releaseAll() {
        teamView = nil
        provider.releaseAll()
    }

    var onContentChange: (() -> Void)? {
        get { provider.onContentChange }
        set { provider.onContentChange = newValue }
    }

    func title(for contribution: String) -> String? {
        contribution == CloudTeamFeature.contribution ? CloudTeamStrings.sectionTitle : provider.title(for: contribution)
    }

    func makeView(for contribution: String) -> NSView? {
        guard contribution == CloudTeamFeature.contribution else { return provider.makeView(for: contribution) }
        if let teamView { return teamView }
        let view = team?()
        view?.onHeightChange = { [weak self] in self?.onContentChange?() }
        teamView = view
        return view
    }

    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        guard contribution == CloudTeamFeature.contribution else { return provider.preferredHeight(for: contribution, width: width) }
        return teamView?.preferredHeight ?? 0
    }
}
