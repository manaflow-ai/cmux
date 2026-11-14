#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileWorkspaces

/// The Workspaces list's pull to refresh under the pull-down search drawer
/// (verify/pull-to-refresh.md). UIKit moves a list's `UIRefreshControl` into
/// the navigation bar behind a collapsible search drawer, where it fights the
/// field: drawn behind it while pulled, then the field jumps 60 pt down and
/// back up. The refresh must stay in the list.
@MainActor
@Suite struct WorkspacesPullToRefreshTests {
    struct Host {
        let window: UIWindow
        let navigation: UINavigationController
        let list: WorkspacesListController
        let view: WorkspacesCollectionView
    }

    /// The Workspaces tab's shape: an inline title over a search drawer that
    /// collapses on scroll, the list as the screen's content scroll view.
    private func host(refresh: @escaping () async -> Void) -> Host {
        let list = WorkspacesListController(control: WorkspacesListControl())
        let view = list.makeView()
        let screen = UIViewController()
        screen.navigationItem.title = "Workspaces"
        screen.navigationItem.largeTitleDisplayMode = .never
        screen.navigationItem.searchController = UISearchController(searchResultsController: nil)
        screen.navigationItem.hidesSearchBarWhenScrolling = true
        view.frame = screen.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        screen.view.addSubview(view)
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        let actions = WorkspacesCollectionActions(
            row: { _ in preconditionFailure("the empty list has no rows") },
            content: { _, _ in AnyView(EmptyView()) },
            menu: { _, _ in nil },
            swipe: { _, _ in nil },
            refresh: refresh
        )
        list.update(model: WorkspacesListModel(), actions: actions, animated: false, membershipKey: 0)
        window.layoutIfNeeded()
        return Host(window: window, navigation: navigation, list: list, view: view)
    }

    private func views(in root: UIView, where match: (UIView) -> Bool) -> [UIView] {
        (match(root) ? [root] : []) + root.subviews.flatMap { views(in: $0, where: match) }
    }

    private func isRefreshUI(_ view: UIView) -> Bool {
        view is UIRefreshControl || view.accessibilityIdentifier == "list.refresh"
    }

    @Test func theRefreshStaysInTheListNotBehindTheSearchDrawer() {
        let host = host(refresh: {})
        #expect(views(in: host.navigation.navigationBar, where: isRefreshUI).isEmpty,
                "the refresh is drawn in the navigation bar, behind the search field")
        #expect(views(in: host.view, where: isRefreshUI).count == 1)
        host.window.isHidden = true
    }
}
#endif
