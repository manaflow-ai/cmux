import AppKit
import CmuxNextApps
import CmuxNextCloudUI
import CmuxNextDaemonService
import CmuxNextSidebar

/// One window's app sections for its sidebar: the platform's
/// `AppSectionProvider`. Per window, because a view has one superview; every
/// mount streams from the app supervisor, which runs one host per app. All
/// chats is not a sidebar section (Lawrence 2026-10-10): it lives on the New
/// Tab page (cx-n0i9). It also draws the window's widget area (`AppWidgetSection`).
@MainActor
final class SidebarAppSections: SidebarAppSectionProvider {
    /// The widget area's section id (never in the layout document).
    static let widgetSectionID = LayoutSectionID("sec_widgets")
    private let provider: AppSectionProvider
    var widgets: AppWidgetSection? { provider.widgets }
    /// The built-in Team section (``CloudTeamFeature/contribution``), drawn here, not by an app.
    private let team: (() -> CloudTeamHostingView?)?
    private var teamView: CloudTeamHostingView?
    /// The Apps tier's section (`experiments.appsTier`, RFD 0003 E-C); nil draws none.
    private let appsTier: AppsTierSidebarFeed?

    init(client: AppsClient, isPresented: @escaping (String) -> Bool, team: (() -> CloudTeamHostingView?)? = nil, appsTier: AppsTierSidebarFeed? = nil) {
        provider = AppSectionProvider(client: client, isPresented: isPresented)
        self.team = team
        self.appsTier = appsTier
        appsTier?.onChange = { [weak self] in self?.onContentChange?() }
        appsTier?.start()
        provider.showWidgets(place: "sidebar")
    }

    /// A section left the window's layout: its app mount ends on the supervisor.
    func release(_ contribution: String) {
        if contribution == CloudTeamFeature.contribution { return teamView = nil }
        if contribution == AppsTierSectionView.contribution { return appsTier?.releaseView() ?? () }
        provider.release(contribution)
    }

    /// Unmounts every app section, widget and workspace list of this window on the supervisor.
    func releaseAll() { teamView = nil; appsTier?.stop(); provider.releaseAll() }

    /// This window's own workspace list (`cmux.sidebar/1`, opt-in; the built-in list otherwise).
    var workspaceList: WorkspaceList? { provider.workspaceList }

    var onContentChange: (() -> Void)? {
        get { provider.onContentChange }
        set { provider.onContentChange = newValue }
    }

    var providedSections: [LayoutSection] {
        let apps = appsTier?.isOn == true ? [AppsTierSectionView.layoutSection] : []
        guard let widgets, widgets.isShown else { return apps }
        return apps + [LayoutSection(id: Self.widgetSectionID, title: widgets.title, region: .bottom, content: .app, contribution: AppWidgetSection.contribution)]
    }

    func title(for contribution: String) -> String? {
        if contribution == AppsTierSectionView.contribution { return AppsTierSectionView.title }
        contribution == CloudTeamFeature.contribution ? CloudTeamStrings.sectionTitle : provider.title(for: contribution)
    }

    func makeView(for contribution: String) -> NSView? {
        if contribution == AppsTierSectionView.contribution { return appsTier?.sectionView() }
        guard contribution == CloudTeamFeature.contribution else { return provider.makeView(for: contribution) }
        if let teamView { return teamView }
        let view = team?()
        view?.onHeightChange = { [weak self] in self?.onContentChange?() }
        teamView = view
        return view
    }

    func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat {
        if contribution == AppsTierSectionView.contribution { return appsTier?.preferredHeight ?? 0 }
        guard contribution == CloudTeamFeature.contribution else { return provider.preferredHeight(for: contribution, width: width) }
        return teamView?.preferredHeight ?? 0
    }
}
