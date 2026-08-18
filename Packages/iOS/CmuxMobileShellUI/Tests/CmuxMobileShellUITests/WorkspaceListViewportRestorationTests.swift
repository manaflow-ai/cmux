#if os(iOS)
import CmuxMobileShellModel
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// Entering a workspace on the compact push stack flips
/// `showsNavigationToolbar` false, and exiting flips it back true. That flip
/// must not change the structural identity of the list subtree: when it does,
/// SwiftUI dismantles the UITableView-backed list on every enter/exit, so the
/// recreated table opens at the top instead of the rows the user left.
@MainActor
@Suite struct WorkspaceListViewportRestorationTests {
    @Test func navigationToolbarFlipResetsOnEnterAndRestoresExactRowOnExit() throws {
        let filterState = WorkspaceListFilterState()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIHostingController(
            rootView: WorkspaceListToolbarFlipHarness(
                showsNavigationToolbar: true,
                filterState: filterState
            )
        )
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        let table = try #require(firstWorkspaceTable(in: window))
        #expect(table.contentSize.height > table.bounds.height * 2)
        table.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        table.layoutIfNeeded()
        let savedOffset = table.contentOffset
        let savedRowID = try #require(firstVisibleWorkspaceRowID(in: table))

        // Entering a workspace hides the list toolbar…
        controller.rootView = WorkspaceListToolbarFlipHarness(
            showsNavigationToolbar: false,
            filterState: filterState
        )
        controller.view.layoutIfNeeded()
        let topOffset = -table.adjustedContentInset.top
        #expect(
            abs(table.contentOffset.y - topOffset) <= 0.5,
            "Entering a workspace must reset the list immediately so the push transition starts from the top."
        )
        #expect(
            firstVisibleWorkspaceRowID(in: table) != savedRowID,
            "Entering a workspace must visibly leave the prior scrolled row behind."
        )

        // …and exiting the workspace restores it.
        controller.rootView = WorkspaceListToolbarFlipHarness(
            showsNavigationToolbar: true,
            filterState: filterState
        )
        controller.view.layoutIfNeeded()

        let tableAfterExit = try #require(firstWorkspaceTable(in: window))
        #expect(
            tableAfterExit === table,
            "The toolbar flip recreated the workspace table, so the viewport cannot survive workspace exit."
        )
        #expect(
            firstVisibleWorkspaceRowID(in: tableAfterExit) == savedRowID,
            "Exiting a workspace must restore the same row at the top of the viewport."
        )
        #expect(
            abs(tableAfterExit.contentOffset.y - savedOffset.y) <= 0.5,
            "Exiting a workspace must restore the exact fractional row position."
        )
        window.isHidden = true
    }

    private func firstWorkspaceTable(in view: UIView) -> WorkspaceListUITableView? {
        if let table = view as? WorkspaceListUITableView {
            return table
        }
        for subview in view.subviews {
            if let table = firstWorkspaceTable(in: subview) {
                return table
            }
        }
        return nil
    }

    private func firstVisibleWorkspaceRowID(in table: UITableView) -> String? {
        let visibleRows = (table.indexPathsForVisibleRows ?? [])
            .sorted { $0.row < $1.row }
        for indexPath in visibleRows {
            guard let cell = table.cellForRow(at: indexPath),
                  let identifier = accessibilityIdentifier(in: cell),
                  identifier.hasPrefix("MobileWorkspaceRow-") else { continue }
            return identifier
        }
        return nil
    }

    private func accessibilityIdentifier(in view: UIView) -> String? {
        if let identifier = view.accessibilityIdentifier {
            return identifier
        }
        for subview in view.subviews {
            if let identifier = accessibilityIdentifier(in: subview) {
                return identifier
            }
        }
        return nil
    }
}

/// Mirrors the live compact shell: `usesExternalSharedToolbar` is true and
/// `showsNavigationToolbar` follows the navigation path, so re-rendering with
/// a flipped flag is exactly what a workspace push/pop does to the list.
private struct WorkspaceListToolbarFlipHarness: View {
    var showsNavigationToolbar: Bool
    let filterState: WorkspaceListFilterState

    private static let workspaces: [MobileWorkspacePreview] = (1...60).map { index in
        MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(index)"),
            name: "workspace-\(index)",
            previewText: "Build succeeded",
            terminals: []
        )
    }

    var body: some View {
        NavigationStack {
            WorkspaceListView(
                workspaces: Self.workspaces,
                selectedWorkspaceID: nil,
                host: "Test Mac",
                connectionStatus: .connected,
                navigationStyle: .push,
                showsNavigationToolbar: showsNavigationToolbar,
                usesExternalSharedToolbar: true,
                wrapWorkspaceTitles: false,
                selectWorkspace: { _ in },
                createWorkspace: {},
                macSelection: .constant(.all),
                filterState: filterState,
                searchText: ""
            )
        }
    }
}
#endif
