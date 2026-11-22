import AppKit
import CmuxNextIcons
import CmuxNextPages
import CmuxNextSidebar

extension InternalPageID {
    /// The Forum as a top page (`experiments.forum`, off by default): its sidebar item and
    /// `forum.show` open it.
    static let forum = InternalPageID(rawValue: "forum")
}

/// The Forum page as a top page: one React page per key, `cmux.forum.` relayed to the daemon (nil: no resources).
@MainActor
final class ForumTopPage: InternalPageProvider {
    private weak var services: AppServices?
    private var pages: [String: PageWebView] = [:]

    init(services: AppServices) { self.services = services }

    var page: InternalPageID { .forum }
    var title: String { SidebarBuiltIn.forum.title }
    var symbol: String { "text.bubble" }
    var icon: IconName? { .agentChatList }

    func makeView(for key: String, in window: WindowController?) -> NSView {
        guard let services, let page = PageWebView(descriptor: .forum, routes: [PageRoute(prefix: "cmux.forum.", provider: DaemonPageRelay(services: services))], route: nil) else { return NSView() }
        PageConnectionWatch(page: page, store: services.machines.local.store).start()
        pages[key] = page
        return page
    }

    func tabClosed(_ key: String) { pages.removeValue(forKey: key)?.close() }
}
