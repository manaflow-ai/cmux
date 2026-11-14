#if os(iOS)
import CmuxMobileDesign
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
    /// A refresh that runs until the test lets it finish.
    @MainActor
    final class Gate {
        private(set) var started = 0
        private var continuation: CheckedContinuation<Void, Never>?

        func run() async {
            started += 1
            await withCheckedContinuation { continuation = $0 }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

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

    /// Yields to the main run loop (its display link draws the frames) until `done`, for at most 3 s.
    private func frames(until done: () -> Bool) async {
        let deadline = CACurrentMediaTime() + 3
        while !done(), CACurrentMediaTime() < deadline { await Task.yield() }
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

    @Test func voiceOverRefreshOpensTheSlotThenClosesIt() async {
        let gate = Gate()
        let host = host(refresh: { await gate.run() })
        let top = host.view.contentInset.top
        #expect(host.view.accessibilityScroll(.up))
        await frames { gate.started == 1 && host.view.contentInset.top == top + ListPullToRefresh.slotHeight }
        #expect(gate.started == 1)
        // The slot opened with the list held at its top: the wheel shows under the search field.
        #expect(host.view.contentInset.top == top + ListPullToRefresh.slotHeight)
        #expect(host.view.contentOffset.y == -host.view.adjustedContentInset.top)
        // A second request while one runs does not start another.
        _ = host.view.accessibilityScroll(.up)
        gate.finish()
        await frames { host.view.contentInset.top == top }
        #expect(host.view.contentInset.top == top)
        #expect(host.view.contentOffset.y == -host.view.adjustedContentInset.top)
        #expect(gate.started == 1)
        host.window.isHidden = true
    }

    @Test func thePullFillsTheWheelThenRefreshesAtTheNativeDistance() {
        #expect(ListPullToRefresh.Pull(distance: 0).ticks == 0)
        #expect(ListPullToRefresh.Pull(distance: -40).ticks == 0)
        #expect(ListPullToRefresh.Pull(distance: 20).ticks == 1)
        let ticks = stride(from: 0, through: 200, by: 2).map { ListPullToRefresh.Pull(distance: CGFloat($0)).ticks }
        #expect(ticks == ticks.sorted(), "the wheel only fills as the pull grows")
        #expect(ListPullToRefresh.Pull(distance: ListPullToRefresh.triggerDistance - 30).ticks == 8)
        #expect(!ListPullToRefresh.Pull(distance: ListPullToRefresh.triggerDistance - 1).triggers)
        #expect(ListPullToRefresh.Pull(distance: ListPullToRefresh.triggerDistance).triggers)
    }
}
#endif
