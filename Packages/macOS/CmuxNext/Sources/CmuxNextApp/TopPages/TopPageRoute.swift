import CmuxNextSidebar

/// A top page (decision TOP-SECTION-ITEMS-ARE-PAGES, Lawrence 2026-10-05:
/// "home/app store/anything in top section should be their own pages"): a
/// sidebar top-section item opens its own page, which fills the window's
/// content area in place of the workspace (no tab strip, panes or splits).
/// One kind with a route per item: Home, or any internal page (the App
/// Store, an app's page, Settings). A new top item is a new route.
/// Client view state (OWNERSHIP-PRINCIPLES): the window that shows it owns
/// it; it persists in the window's record, never in the shared tree.
nonisolated enum TopPageRoute: Hashable, Sendable {
    /// The chief conversation, natively (Home's content).
    case home
    /// An internal page's provider fills the page (`InternalPageProvider`).
    case page(InternalPageID)

    /// The persisted form: `home`, else `page:<internal page id>`.
    var rawValue: String {
        switch self {
        case .home: Self.homeRaw
        case .page(let id): Self.pagePrefix + id.rawValue
        }
    }

    init?(rawValue: String) {
        if rawValue == Self.homeRaw {
            self = .home
        } else if rawValue.hasPrefix(Self.pagePrefix), rawValue.count > Self.pagePrefix.count {
            self = .page(InternalPageID(rawValue: String(rawValue.dropFirst(Self.pagePrefix.count))))
        } else {
            return nil
        }
    }

    private static let homeRaw = "home"
    private static let pagePrefix = "page:"
}

@MainActor
extension TopPageRoute {
    /// The page an item opens when it sits in a section of `region`: only
    /// top-region items open pages (Settings at the bottom stays a tab).
    /// Launchers (New Workspace, Import) and workspace refs open no page.
    init?(_ ref: LayoutItemRef, in region: SidebarRegion) {
        guard region == .top, let route = Self.route(for: ref) else { return nil }
        self = route
    }

    /// The page `ref` stands for in any section (the active-item check).
    static func route(for ref: LayoutItemRef) -> TopPageRoute? {
        if ref.kind != "" { return nil } // RED stub: no item opens a page yet
        if ref.kind == LayoutItemRef.appKind {
            switch ref.value {
            case homeAppID: return .home
            case appStoreAppID: return .page(.appStore)
            case CodeRouterPageTab.appID: return .page(.coderouter)
            default: return .page(AppPanePage.pageID(ref.value))
            }
        }
        switch ref.builtIn {
        case .home: return .home
        case .appStore: return .page(.appStore)
        case .settings: return .page(.settings)
        default: return nil
        }
    }

    static let homeAppID = "cmux/home"
    static let appStoreAppID = "cmux/app-store"
}

extension SidebarLayoutDocument {
    /// The region of the section that holds item `id`.
    func region(of id: LayoutItemID) -> SidebarRegion? {
        locate(id).map { sections[$0.section].region }
    }
}
