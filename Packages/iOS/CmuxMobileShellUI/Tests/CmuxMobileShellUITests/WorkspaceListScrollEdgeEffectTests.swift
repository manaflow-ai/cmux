#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// SwiftUI does not register a represented UIKit table with its enclosing
/// bars. These tests pin the controller contract that makes the soft scroll
/// edge effect render without taking inset or offset ownership from UIKit.
@MainActor
@Suite struct WorkspaceListScrollEdgeEffectTests {
    @Test func hostedTableDrivesNavigationAndTabBarScrollEdgeEffects() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = Fixture()

        #expect(fixture.content.contentScrollView(for: .top) === fixture.tableView)
        #expect(fixture.navigation.contentScrollView(for: .bottom) === fixture.tableView)
    }

    @Test func underlappedTableUsesParentChromeAsUIKitSafeArea() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = Fixture()

        #expect(fixture.tableView.frame == fixture.content.view.bounds)
        #expect(fixture.tableView.safeAreaInsets.top > 0)
        #expect(fixture.tableView.safeAreaInsets.bottom > 0)
        #expect(fixture.tableView.adjustedContentInset.top > 0)
        #expect(fixture.tableView.adjustedContentInset.bottom > 0)
        #expect(fixture.tableView.contentInset == .zero)
    }

    @Test func tableLeavingTheWindowReleasesBarRegistrations() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = Fixture()

        fixture.tableView.removeFromSuperview()

        #expect(fixture.content.contentScrollView(for: .top) == nil)
        #expect(fixture.navigation.contentScrollView(for: .bottom) == nil)
    }

    /// The controller chain can assemble incrementally: the navigation
    /// controller can host the table before it joins a tab bar controller.
    /// Whichever lifecycle path fires for the move (UIKit container
    /// attachment always relocates the child's view, so `didMoveToWindow`
    /// and layout passes both run), the bottom edge must end registered.
    /// UIKit's hierarchy-consistency check forbids re-parenting a controller
    /// whose view stays in a foreign hierarchy, so a window-stable variant of
    /// this scenario is not constructible; the window-stable layout-retry
    /// path is covered by
    /// ``survivingTableReclaimsRegistrationAfterOwnerDeparts()``.
    @Test func lateTabControllerAttachmentStillRegistersBottomEdge() throws {
        guard #available(iOS 26.0, *) else { return }
        let tableController = WorkspaceListTableViewController()
        let tableView = tableController.tableView
        let content = UIViewController()
        Self.install(tableController, in: content)
        let navigation = UINavigationController(rootViewController: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        content.view.layoutIfNeeded()
        #expect(content.contentScrollView(for: .top) === tableView)
        #expect(navigation.contentScrollView(for: .bottom) == nil)

        let tabs = UITabBarController()
        window.rootViewController = tabs
        tabs.viewControllers = [navigation]
        window.layoutIfNeeded()
        tableView.setNeedsLayout()
        tableView.layoutIfNeeded()

        #expect(content.contentScrollView(for: .top) === tableView)
        #expect(navigation.contentScrollView(for: .bottom) === tableView)
    }

    /// While two live tables coexist (SwiftUI transition overlap), the later
    /// one must not steal the registration: ownership would otherwise become
    /// layout-order dependent and thrash on every pass.
    @Test func coexistingTablesDoNotStealRegistrationFromEachOther() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = Fixture()
        let secondController = WorkspaceListTableViewController()
        let second = secondController.tableView

        Self.install(secondController, in: fixture.content)
        fixture.content.view.layoutIfNeeded()
        #expect(fixture.content.contentScrollView(for: .top) === fixture.tableView)

        second.setNeedsLayout()
        second.layoutIfNeeded()
        fixture.tableView.setNeedsLayout()
        fixture.tableView.layoutIfNeeded()

        #expect(fixture.content.contentScrollView(for: .top) === fixture.tableView)
        #expect(fixture.navigation.contentScrollView(for: .bottom) === fixture.tableView)
    }

    /// When SwiftUI dismantles the owning table controller, it clears the
    /// edges and wakes the waiting table. Reclaim may happen synchronously or
    /// on the next layout pass, but the departed table must never remain held.
    @Test func survivingTableReclaimsRegistrationAfterOwnerDeparts() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = Fixture()
        let secondController = WorkspaceListTableViewController()
        let second = secondController.tableView
        Self.install(secondController, in: fixture.content)
        fixture.content.view.layoutIfNeeded()
        #expect(fixture.content.contentScrollView(for: .top) === fixture.tableView)

        fixture.tableController.detach()
        #expect(fixture.content.contentScrollView(for: .top) !== fixture.tableView)

        fixture.window.layoutIfNeeded()

        #expect(fixture.content.contentScrollView(for: .top) === second)
        #expect(fixture.navigation.contentScrollView(for: .bottom) === second)
    }

    /// Table hosted under `UITabBarController > UINavigationController >
    /// content`, mirroring the shell's TabView + NavigationStack chrome.
    @MainActor
    private struct Fixture {
        let tableView: WorkspaceListUITableView
        let tableController: WorkspaceListTableViewController
        let content: UIViewController
        let navigation: UINavigationController
        let tabs: UITabBarController
        let window: UIWindow

        init() {
            tableController = WorkspaceListTableViewController()
            tableView = tableController.tableView
            content = UIViewController()
            WorkspaceListScrollEdgeEffectTests.install(
                tableController,
                in: content
            )
            navigation = UINavigationController(rootViewController: content)
            tabs = UITabBarController()
            tabs.viewControllers = [navigation]
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = tabs
            window.isHidden = false
            window.layoutIfNeeded()
            content.view.layoutIfNeeded()
        }
    }

    private static func install(
        _ child: UIViewController,
        in parent: UIViewController
    ) {
        parent.addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
        ])
        child.didMove(toParent: parent)
    }
}
#endif
