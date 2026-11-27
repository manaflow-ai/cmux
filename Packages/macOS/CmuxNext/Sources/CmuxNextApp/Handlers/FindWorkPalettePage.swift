import CmuxNextPalette
import Foundation
import CmuxNextFeedClient

/// The command palette's Find Work page (`palette.findWork`, classic
/// `ContentView+CurrentWorkCommandPalette`): the work already known to cmux. Workspaces with
/// unread notifications come first, then the other workspaces; a row switches to its workspace.
/// Below them, the user's open GitHub review requests and assignments (read with their `gh`
/// login by the daemon's GitHub poster, `feed.github.find_work`, never prompting) open in a new workspace.
@MainActor
struct FindWorkPalettePage {
    let services: AppServices
    /// The GitHub reads (`feed.github.find_work`); tests pass a fake.
    var github: @MainActor () async throws -> FeedGitHubWork.Lists
    /// Opens a GitHub row's page; tests record it.
    var open: @MainActor (URL) -> Void

    init(services: AppServices, github: (@MainActor () async throws -> FeedGitHubWork.Lists)? = nil, open: (@MainActor (URL) -> Void)? = nil) {
        self.services = services
        let daemon = services.feed.daemon
        self.github = github ?? { try await daemon.findWork() }
        self.open = open ?? { [weak services] url in
            guard let services else { return }
            WorkspaceHandlers.openInNewWorkspace(url, services: services)
        }
    }

    static let attentionSection = PaletteSection(id: "findWork.attention", title: FindWorkStrings.needsAttention, order: 0)
    static let workspacesSection = PaletteSection(id: "findWork.workspaces", title: FindWorkStrings.workspaces, order: 1)
    static let reviewSection = PaletteSection(id: "findWork.reviews", title: FindWorkStrings.reviewRequests, order: 2)
    static let assignedSection = PaletteSection(id: "findWork.assigned", title: FindWorkStrings.assigned, order: 3)

    func page() -> PalettePageSpec {
        let github = github, open = open
        let workspaces = StaticPaletteProvider(id: "findWork.workspaces", items: workspaceItems())
        let remote = AsyncPaletteProvider(id: "findWork.github") { await Self.githubItems(github, open: open) }
        var page = PalettePageSpec(id: "findWork", title: FindWorkStrings.title, placeholder: FindWorkStrings.placeholder,
                                   symbol: "sparkle.magnifyingglass", providers: [workspaces, remote])
        page.keepsSectionOrder = true
        return page
    }

    /// Every workspace the palette knows, those needing attention first (most unread first).
    func workspaceItems() -> [PaletteItem] {
        guard let source = services.palette.sources.workspaces else { return [] }
        let all = source.workspaces.enumerated().sorted { lhs, rhs in
            (lhs.element.unreadCount, -lhs.offset) > (rhs.element.unreadCount, -rhs.offset)
        }.map(\.element)
        return all.map { workspace in
            let id = workspace.id
            let attention = workspace.unreadCount > 0
            return PaletteItem(
                id: "work.workspace:\(id)", title: workspace.title,
                subtitle: workspace.directory.map { ($0 as NSString).abbreviatingWithTildeInPath },
                accessory: attention ? FindWorkStrings.unread(workspace.unreadCount) : nil,
                symbol: attention ? "bell.badge" : "rectangle.stack",
                section: attention ? Self.attentionSection : Self.workspacesSection,
                keywords: [workspace.groupName, workspace.directory].compactMap { $0 },
                primary: PaletteCommand(id: "select", title: FindWorkStrings.switchTo, symbol: "return",
                                        effect: .perform { source.selectWorkspace(id: id) }))
        }
    }

    /// The user's review requests, then their assigned issues and pull requests (one row per
    /// item); a row explaining why when gh cannot answer.
    static func githubItems(_ github: @MainActor () async throws -> FeedGitHubWork.Lists, open: @escaping @MainActor (URL) -> Void) async -> [PaletteItem] {
        var seen = Set<String>(), items: [PaletteItem] = []
        do {
            let work = try await github()
            for item in work.reviews where seen.insert(item.url).inserted {
                items.append(row(item, section: reviewSection, symbol: "arrow.triangle.pull", open: open))
            }
            for item in work.assigned where seen.insert(item.url).inserted {
                items.append(row(item, section: assignedSection, symbol: item.isPull ? "arrow.triangle.pull" : "smallcircle.filled.circle", open: open))
            }
        } catch {
            items.append(PaletteItem(id: "work.github.unavailable", title: FindWorkStrings.githubUnavailable,
                                     subtitle: FindWorkStrings.githubUnavailableDetail, symbol: "exclamationmark.triangle",
                                     section: reviewSection, isEnabled: false,
                                     primary: PaletteCommand(id: "none", title: FindWorkStrings.githubUnavailable, effect: .perform {})))
        }
        return items
    }

    private static func row(_ item: FeedGitHubWork, section: PaletteSection, symbol: String,
                            open: @escaping @MainActor (URL) -> Void) -> PaletteItem {
        let url = URL(string: item.url)
        return PaletteItem(
            id: "work.github:\(item.url)", title: item.title,
            subtitle: "\(item.repo)#\(item.number)",
            accessory: item.author, symbol: symbol, section: section,
            keywords: [item.repo, "#\(item.number)", item.author].compactMap { $0 },
            isEnabled: url != nil,
            primary: PaletteCommand(id: "open", title: FindWorkStrings.openInNewWorkspace, symbol: "return",
                                    effect: .perform { if let url { open(url) } }))
    }
}
