import AppKit
import CmuxAgentBrands
import CmuxNextAgentPane
import CmuxNextSidebar

/// One window's Recents section (`SidebarRecentsView.contribution`): the
/// shared feed's chats as rows, each opening its chat as a session link
/// does. With no chats there is no view, so the section draws nothing. The
/// window's project filter (Leo, T3 Code ref) picks the chats of one
/// folder; it clears when that folder has no chats left.
@MainActor
final class AgentRecentsSection {
    private let feed: AgentRecentsFeed
    private let view = SidebarRecentsView()
    private var project: String?
    private var shown: [AcpmuxRecentChat] = []
    var onContentChange: (() -> Void)?

    init(feed: AgentRecentsFeed, open: @escaping (String) -> Void) {
        self.feed = feed
        view.onOpen = open
        view.onFilter = { [weak self] project in
            self?.project = project
            self?.refresh()
        }
        refresh()
        feed.observe(self) { [weak self] in self?.refresh() }
    }

    var contentView: NSView? { feed.chats.isEmpty ? nil : view }
    var height: CGFloat { SidebarRecentsView.height(rows: shown.count, filter: view.showsFilter) }

    private func refresh() {
        let projects = feed.projects
        if let project, !projects.contains(project) { self.project = nil }
        shown = feed.newest(in: project)
        view.updateProjects(projects, selected: project)
        view.update(shown.map { chat in
            SidebarRecentsView.Row(id: chat.id, title: chat.title ?? SidebarRecentsView.newChatTitle,
                                   brand: AgentBrandCatalog.brand(for: chat.harness)?.rawValue)
        })
        onContentChange?()
    }
}
