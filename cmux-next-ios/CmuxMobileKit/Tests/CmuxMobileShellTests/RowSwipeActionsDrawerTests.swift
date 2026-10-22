#if os(iOS)
@testable import CmuxMobileDesign
import Testing
import UIKit
@testable import CmuxMobileShell

/// User report 2026-10-21: with a row's swipe actions open, a rightward
/// swipe opened the team drawer. As in Mail and Messages, it closes the
/// actions first; the drawer opens only when no row actions are open, on
/// every list (Workspaces, Home and Settings are `List`s; the Feed draws
/// its own rows).
@MainActor
@Suite(.serialized) struct RowSwipeActionsDrawerTests {
    /// The shell's drawer over `content`, in a window, laid out.
    func container(content: UIViewController) -> (SidebarContainerViewController, UIWindow) {
        let controller = SidebarContainerViewController(model: SidebarModel(), sidebar: UIViewController(), content: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, window)
    }

    /// A plain list with rows; `slid` moves the first row's cell as an open
    /// swipe does.
    final class ListController: UITableViewController {
        override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 8 }
        override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.textLabel?.text = "Row \(indexPath.row)"
            return cell
        }
    }

    @Test func aRightwardSwipeOpensTheDrawerWhenNoRowIsOpen() {
        RowSwipeActions.shared.closeAll()
        let list = ListController(style: .plain)
        let (drawer, window) = container(content: list)
        defer { window.isHidden = true }
        list.tableView.layoutIfNeeded()
        #expect(!RowSwipeActions.hasOpenListRow(in: list.view))
        #expect(drawer.mayOpen(at: CGPoint(x: 200, y: 300)))
    }

    @Test func anOpenListRowTakesTheRightwardSwipeInsteadOfTheDrawer() throws {
        RowSwipeActions.shared.closeAll()
        let list = ListController(style: .plain)
        let (drawer, window) = container(content: list)
        defer { window.isHidden = true }
        list.tableView.layoutIfNeeded()
        let cell = try #require(list.tableView.cellForRow(at: IndexPath(row: 1, section: 0)))
        // UIKit slides an open row's cell left over its actions.
        cell.frame.origin.x = -180
        #expect(RowSwipeActions.hasOpenListRow(in: list.view))
        #expect(!drawer.mayOpen(at: CGPoint(x: 200, y: 600)), "a swipe anywhere closes the open row first")
    }

    /// UIKit keeps its swipe actions view in the list at full width after
    /// the row closes (iOS 26.5): it must not keep the drawer shut.
    @Test func aClosedRowsLeftoverActionsViewDoesNotBlockTheDrawer() {
        RowSwipeActions.shared.closeAll()
        let list = ListController(style: .plain)
        let (drawer, window) = container(content: list)
        defer { window.isHidden = true }
        list.tableView.layoutIfNeeded()
        final class LeftoverSwipeActionsView: UIView {}
        list.tableView.addSubview(LeftoverSwipeActionsView(frame: CGRect(x: 0, y: 44, width: 402, height: 44)))
        #expect(!RowSwipeActions.hasOpenListRow(in: list.view))
        #expect(drawer.mayOpen(at: CGPoint(x: 200, y: 300)))
    }

    @Test func anOpenFeedRowClosesInsteadOfOpeningTheDrawer() {
        RowSwipeActions.shared.closeAll()
        let (drawer, window) = container(content: UIViewController())
        defer { window.isHidden = true }
        var closed = false
        RowSwipeActions.shared.setOpen("feed.e1", close: { closed = true })
        #expect(!drawer.mayOpen(at: CGPoint(x: 200, y: 300)))
        #expect(closed, "the open row was closed")
        #expect(!RowSwipeActions.shared.hasOpenRow)
        // The next rightward swipe opens the drawer.
        #expect(drawer.mayOpen(at: CGPoint(x: 200, y: 300)))
    }

    @Test func theDrawerWaitsForARowsOwnPan() throws {
        let (drawer, window) = container(content: UIViewController())
        defer { window.isHidden = true }
        let pan = try #require(drawer.view.gestureRecognizers?.first { $0 is UIPanGestureRecognizer })
        let rowPan = UIPanGestureRecognizer()
        rowPan.name = RowSwipeActions.panName
        #expect(drawer.gestureRecognizer(pan, shouldRequireFailureOf: rowPan))
        #expect(!drawer.gestureRecognizer(pan, shouldRequireFailureOf: UIPanGestureRecognizer()))
    }

    /// SwiftUI's List slides the open row's cell and its layout attributes
    /// together (iOS 26.5: x = -242), so the cell is read against its siblings.
    @Test func anOpenListCellIsTheOneOffTheSharedEdge() {
        #expect(!RowSwipeActions.hasSlidCell([0, 0, 0, 0]))
        #expect(RowSwipeActions.hasSlidCell([0, -242, 0, 0]))
        #expect(RowSwipeActions.hasSlidCell([-242]), "a lone open row")
        #expect(!RowSwipeActions.hasSlidCell([16, 16, 16]), "an inset list at rest")
        #expect(RowSwipeActions.hasSlidCell([16, 16, -60, 16]))
        #expect(!RowSwipeActions.hasSlidCell([]))
    }

    @Test func feedButtonsMatchListSwipeActions() {
        let style = RowSwipeActionStyle.standard
        // Two actions: 2 x 66 buttons, 2 x 12 gaps, 10 inset.
        #expect(style.revealWidth(count: 2) == 166)
        #expect(style.buttonWidth(revealed: 166, count: 2) == 66)
        #expect(style.buttonWidth(revealed: 83, count: 2) == 24.5)
        #expect(style.buttonWidth(revealed: 10, count: 2) == 0)
        #expect(style.fullSwipeWidth(revealed: 300) == 278)
    }
}
#endif
