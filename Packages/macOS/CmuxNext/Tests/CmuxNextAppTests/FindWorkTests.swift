import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFeedClient
import CmuxNextPalette
import Foundation
import Testing

/// Find Work (`palette.findWork`, classic `ContentView+CurrentWorkCommandPalette`): a palette page
/// of the work already known to cmux. Workspaces that need attention come first, then the
/// other workspaces; a row switches to its workspace. The user's GitHub review requests and
/// assignments (their `gh` login) follow, each opening in a new workspace.
@MainActor @Suite(.serialized)
struct FindWorkTests {
    final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace]
        var selected: [String] = []
        init(_ workspaces: [PaletteWorkspace]) { self.workspaces = workspaces }
        func selectWorkspace(id: String) { selected.append(id) }
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    static func services() -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        return services
    }

    static func items(_ page: PalettePageSpec) async -> [PaletteItem] {
        var items: [PaletteItem] = []
        for provider in page.providers { items += await provider.items() }
        return items
    }

    @Test func findWorkIsAvailable() {
        let services = Self.services()
        #expect(services.registry.unavailableReason(for: "palette.findWork") == nil)
    }

    @Test func pageListsWorkspacesNeedingAttentionFirstAndSwitchesToThem() async throws {
        let services = Self.services()
        let source = Workspaces([
            PaletteWorkspace(id: "ws-quiet", title: "Quiet", directory: "/tmp/quiet"),
            PaletteWorkspace(id: "ws-loud", title: "Loud", unreadCount: 2),
        ])
        services.palette.sources.workspaces = source
        let page = try #require(services.palette.sources.actionPages["palette.findWork"]?())
        #expect(page.id == "findWork")
        let rows = await Self.items(page).filter { $0.id.hasPrefix("work.workspace:") }
        #expect(rows.map(\.id) == ["work.workspace:ws-loud", "work.workspace:ws-quiet"])
        #expect(rows.first?.section != rows.last?.section)
        guard case .perform(let run) = try #require(rows.first).primary.effect else {
            Issue.record("a workspace row switches to it")
            return
        }
        run()
        #expect(source.selected == ["ws-loud"])
    }

    /// The daemon's `feed.github.find_work` reply (the user's `gh` login), or its refusal.
    struct GitHubUnavailable: Error {}
    static func github(fails: Bool = false) -> @MainActor () async throws -> FeedGitHubWork.Lists {
        {
            if fails { throw GitHubUnavailable() }
            let fix = FeedGitHubWork(title: "Fix login", url: "https://github.com/acme/app/pull/7", repo: "acme/app", number: 7, author: "octo")
            let crash = FeedGitHubWork(title: "Crash on start", url: "https://github.com/acme/app/issues/9", repo: "acme/app", number: 9, author: "octo")
            return FeedGitHubWork.Lists(reviews: [fix], assigned: [fix, crash])
        }
    }

    @Test func gitHubReviewRequestsAndAssignmentsOpenInANewWorkspace() async throws {
        let services = Self.services()
        var opened: [URL] = []
        let page = FindWorkPalettePage(services: services, github: Self.github(), open: { opened.append($0) }).page()
        let rows = await Self.items(page).filter { $0.id.hasPrefix("work.github:") }
        #expect(rows.map(\.title) == ["Fix login", "Crash on start"])
        #expect(rows.map(\.subtitle) == ["acme/app#7", "acme/app#9"])
        #expect(rows[0].section != rows[1].section)
        guard case .perform(let run) = rows[1].primary.effect else {
            Issue.record("a GitHub row opens its page")
            return
        }
        run()
        #expect(opened == [URL(string: "https://github.com/acme/app/issues/9")!])
    }

    @Test func gitHubFailureShowsWhyInsteadOfRows() async {
        let services = Self.services()
        let rows = await Self.items(FindWorkPalettePage(services: services, github: Self.github(fails: true)).page())
        #expect(rows.contains { $0.id == "work.github.unavailable" && !$0.isEnabled })
        #expect(!rows.contains { $0.id.hasPrefix("work.github:") })
    }
}
