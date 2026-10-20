import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextPalette
import Foundation
import Testing

/// Find Work (`palette.findWork`, classic `ContentView+CurrentWorkCommandPalette`): a palette page
/// of the work already known to cmux. Workspaces that need attention come first, then the
/// other workspaces; a row switches to its workspace.
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
}
