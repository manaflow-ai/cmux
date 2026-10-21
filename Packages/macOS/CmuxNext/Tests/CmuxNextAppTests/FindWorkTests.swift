import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFeed
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
        services.findWorkGitHub = FakeGitHub()
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

    nonisolated struct FakeGitHub: GitHubFeedAPI {
        var fails = false
        static let date = Date(timeIntervalSince1970: 1_700_000_000)
        static func item(_ number: Int, _ title: String, kind: String) -> GitHubReviewRequest {
            GitHubReviewRequest(id: number, number: number, title: title, htmlURL: "https://github.com/acme/app/\(kind)/\(number)",
                                repository: .init(fullName: "acme/app"), user: .init(login: "octo"), updatedAt: date)
        }
        func notifications(etag: String?) async throws -> GitHubAPIResponse<[GitHubNotification]> { GitHubAPIResponse(value: []) }
        func reviewRequests(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
            if fails { throw GitHubFeedError.cliUnavailable("gh: not logged in") }
            return GitHubAPIResponse(value: [Self.item(7, "Fix login", kind: "pull")])
        }
        func assignedWork(etag: String?) async throws -> GitHubAPIResponse<[GitHubReviewRequest]> {
            GitHubAPIResponse(value: [Self.item(7, "Fix login", kind: "pull"), Self.item(9, "Crash on start", kind: "issues")])
        }
    }

    @Test func gitHubReviewRequestsAndAssignmentsOpenInANewWorkspace() async throws {
        let services = Self.services()
        services.findWorkGitHub = FakeGitHub()
        var opened: [URL] = []
        let page = FindWorkPalettePage(services: services, open: { opened.append($0) }).page()
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
        services.findWorkGitHub = FakeGitHub(fails: true)
        let rows = await Self.items(FindWorkPalettePage(services: services).page())
        #expect(rows.contains { $0.id == "work.github.unavailable" && !$0.isEnabled })
        #expect(!rows.contains { $0.id.hasPrefix("work.github:") })
    }
}
