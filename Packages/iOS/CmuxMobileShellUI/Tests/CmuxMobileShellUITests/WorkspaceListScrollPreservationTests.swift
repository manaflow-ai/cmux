#if os(iOS)
import CmuxMobileShellModel
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// Entering a workspace on the compact stack flips the list's
/// `showsNavigationToolbar` off, and exiting flips it back on. The list's
/// structural identity must not depend on that flag: an identity change
/// dismantles the represented workspace table, so the freshly created table
/// comes back scrolled to the top (issue #10481).
@MainActor
@Suite struct WorkspaceListScrollPreservationTests {
    @Test func workspaceTableSurvivesNavigationToolbarRoundTrip() async throws {
        let fixture = Fixture(workspaceCount: 40)
        defer { fixture.tearDown() }
        await fixture.render(showsNavigationToolbar: true)

        let table = try #require(fixture.currentTable())
        let offset = CGPoint(x: 0, y: 240)
        table.setContentOffset(offset, animated: false)

        // Enter a workspace (list covered, toolbar hidden), then exit back.
        await fixture.render(showsNavigationToolbar: false)
        await fixture.render(showsNavigationToolbar: true)

        let tableAfter = try #require(fixture.currentTable())
        #expect(
            tableAfter === table,
            "Toolbar visibility must not change the list's structural identity; a rebuilt table loses the scroll position."
        )
        #expect(tableAfter.contentOffset == offset)
    }

    @Test func workspaceTableKeepsOffsetWhenContentRefreshesWhileCovered() async throws {
        let fixture = Fixture(workspaceCount: 40)
        defer { fixture.tearDown() }
        await fixture.render(showsNavigationToolbar: true)

        let table = try #require(fixture.currentTable())
        let offset = CGPoint(x: 0, y: 240)
        table.setContentOffset(offset, animated: false)

        // While the workspace is open, the Mac appends new rows to the list.
        await fixture.render(showsNavigationToolbar: false)
        await fixture.render(showsNavigationToolbar: false, workspaceCount: 44)
        await fixture.render(showsNavigationToolbar: true, workspaceCount: 44)

        let tableAfter = try #require(fixture.currentTable())
        #expect(tableAfter === table)
        #expect(tableAfter.contentOffset == offset)
        #expect(tableAfter.numberOfRows(inSection: 0) >= 44)
    }

    /// Hosts the real `WorkspaceListView` the way the compact shell does: at
    /// the root of a `NavigationStack`, re-rendered with a new
    /// `showsNavigationToolbar` value on every push/pop.
    @MainActor
    private final class Fixture {
        private let window: UIWindow
        private let host: UIHostingController<Harness>
        private let filterState = WorkspaceListFilterState()

        init(workspaceCount: Int) {
            host = UIHostingController(
                rootView: Harness(
                    workspaces: Self.workspaces(count: workspaceCount),
                    showsNavigationToolbar: true,
                    filterState: filterState
                )
            )
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
        }

        func render(showsNavigationToolbar: Bool, workspaceCount: Int? = nil) async {
            host.rootView = Harness(
                workspaces: Self.workspaces(
                    count: workspaceCount ?? host.rootView.workspaces.count
                ),
                showsNavigationToolbar: showsNavigationToolbar,
                filterState: filterState
            )
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            // Let SwiftUI commit deferred hierarchy updates (representable
            // dismantles land on a later main-queue turn).
            for _ in 0..<20 {
                await Task.yield()
            }
            window.layoutIfNeeded()
        }

        func currentTable() -> WorkspaceListUITableView? {
            Self.findTable(in: window)
        }

        func tearDown() {
            window.isHidden = true
            window.rootViewController = nil
        }

        private static func findTable(in view: UIView) -> WorkspaceListUITableView? {
            if let table = view as? WorkspaceListUITableView { return table }
            for subview in view.subviews {
                if let table = findTable(in: subview) { return table }
            }
            return nil
        }

        private static func workspaces(count: Int) -> [MobileWorkspacePreview] {
            (1...count).map { index in
                MobileWorkspacePreview(
                    id: .init(rawValue: "workspace-\(index)"),
                    name: "Workspace \(index)",
                    previewText: "Agent activity \(index)",
                    terminals: []
                )
            }
        }
    }

    private struct Harness: View {
        let workspaces: [MobileWorkspacePreview]
        let showsNavigationToolbar: Bool
        let filterState: WorkspaceListFilterState

        var body: some View {
            NavigationStack {
                WorkspaceListView(
                    workspaces: workspaces,
                    selectedWorkspaceID: nil,
                    host: "Test Mac",
                    connectionStatus: .connected,
                    navigationStyle: .push,
                    showsNavigationToolbar: showsNavigationToolbar,
                    usesExternalSharedToolbar: true,
                    wrapWorkspaceTitles: false,
                    selectWorkspace: { _ in },
                    createWorkspace: {},
                    macSelection: .constant(.automatic),
                    filterState: filterState
                )
            }
        }
    }
}
#endif
