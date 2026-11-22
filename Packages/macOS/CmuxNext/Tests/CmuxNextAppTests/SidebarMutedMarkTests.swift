import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// nxdog62 (b): a workspace in `notifications.mutedWorkspaces` showed no
/// mark on its sidebar row, and `debug.sidebar_rows` could not tell. A muted
/// row says so (a subtle mark plus its accessibility label), and the debug
/// report carries `muted` for every row.
@MainActor
@Suite(.serialized)
struct SidebarMutedMarkTests {
    @Test func aMutedWorkspaceRowShowsTheMarkAndTheReportSaysMuted() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try ProviderTabOpenTests.tree(surfaces: [5]))
        let workspace = try #require(services.daemon.store.workspaces.first)
        let window = try #require(services.windows.openWindow(workspaces: [workspace.id]))
        services.windows.didActivate(window)
        let sidebar = window.sidebar.container.sidebarView
        await BrowserTabTests.settle { !sidebar.model.sections.flatMap(\.workspaces).isEmpty }
        // The list lays out rows only inside its frame.
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        func relayout() {
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
        }
        relayout()

        #expect(try Self.mutedField(services, title: workspace.displayName) == false, "a row that is not muted reports false")

        services.notifications.preferences.mutedWorkspaces = [workspace.id]
        await BrowserTabTests.settle {
            relayout()
            return (try? Self.mutedField(services, title: workspace.displayName)) == true
        }
        #expect(try Self.mutedField(services, title: workspace.displayName) == true)

        relayout()
        let row = try #require(sidebar.list.rowViews[.workspace(CmuxNextSidebar.WorkspaceID(workspace.id))])
        let label = row.accessibilityLabel() ?? ""
        #expect(label.contains("Muted"), "VoiceOver hears the mute: \(label)")
        window.teardown()
        withExtendedLifetime(services) {}
    }

    /// The `muted` field of the window's row titled `title` (nil: the
    /// report has no such field).
    static func mutedField(_ services: AppServices, title: String) throws -> Bool? {
        let report = DebugSidebarRows.report(services: services)
        let rows = report["windows"]?.arrayValue?.flatMap { $0["rows"]?.arrayValue ?? [] } ?? []
        let row = try #require(rows.first { $0["title"]?.stringValue == title }, "rows: \(rows.map { $0["title"]?.stringValue ?? "-" })")
        return row["muted"]?.boolValue
    }
}
