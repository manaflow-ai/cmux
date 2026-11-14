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

    /// A scroll view whose finger and coasting the test decides.
    final class FingerScrollView: UIScrollView {
        var fingerDown = false
        var coasting = false
        override var isDragging: Bool { fingerDown }
        override var isDecelerating: Bool { coasting }
    }

    /// A list under no bars (top inset 0) in a window, with every offset it is given recorded.
    private func fingerList(refresh: @escaping () async -> Void) -> (UIWindow, FingerScrollView, ListPullToRefresh) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let list = FingerScrollView(frame: root.view.bounds)
        list.contentInsetAdjustmentBehavior = .never
        list.contentSize = CGSize(width: 402, height: 4000)
        root.view.addSubview(list)
        return (window, list, ListPullToRefresh(scrollView: list, action: refresh))
    }

    private func wheel(_ list: UIScrollView) -> UIView? {
        list.subviews.first { $0.accessibilityIdentifier == "list.refresh" }
    }

    @Test func aPullRefreshesOpensTheSlotWhenTheFingerLiftsAndClosesAtRest() async throws {
        let gate = Gate()
        let (window, list, refresh) = fingerList(refresh: { await gate.run() })
        // The finger pulls past the refresh distance: the refresh starts, the inset stays (no rubber-band restart).
        list.fingerDown = true
        list.contentOffset.y = -(ListPullToRefresh.triggerDistance + 10)
        refresh.scrolled()
        await frames { gate.started == 1 }
        #expect(gate.started == 1)
        #expect(list.contentInset.top == 0)
        // The finger lifts: the slot opens and the bounce ends at its top.
        var target = list.contentOffset
        refresh.willEndDragging(targetContentOffset: &target)
        #expect(list.contentInset.top == ListPullToRefresh.slotHeight)
        #expect(target.y == -ListPullToRefresh.slotHeight)
        list.fingerDown = false
        // Scrolled into the rows mid-refresh, the wheel stays in its slot, not behind the first row.
        list.contentOffset.y = 300
        refresh.scrolled()
        let spinning = try #require(wheel(list))
        #expect(!spinning.isHidden)
        #expect(spinning.center.y == -ListPullToRefresh.slotHeight / 2)
        // Back up and still springing when the refresh ends: nothing moves until the list rests.
        list.coasting = true
        list.contentOffset.y = -120
        refresh.scrolled()
        gate.finish()
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(list.contentInset.top == ListPullToRefresh.slotHeight, "the slot closed while UIKit was still moving the list")
        // At rest inside the slot (20 pt into it): the slot closes and the rows move with it, a little per frame.
        list.coasting = false
        list.contentOffset.y = -40
        var offsets: [CGFloat] = []
        let watch = list.observe(\.contentOffset, options: [.new]) { _, change in
            if let y = change.newValue?.y { MainActor.assumeIsolated { offsets.append(y) } }
        }
        refresh.endedDecelerating()
        await frames { list.contentInset.top == 0 }
        watch.invalidate()
        #expect(list.contentInset.top == 0)
        #expect(list.contentOffset.y == 0)
        let steps = zip([-40] + offsets, offsets).map { abs($1 - $0) }
        #expect((steps.max() ?? 0) < 12, "a frame moved the rows \(steps.max() ?? 0) pt")
        window.isHidden = true
    }

    @Test func aRefreshThatEndsUnderTheFingerClosesTheSlotWhenItLifts() async {
        let gate = Gate()
        let (window, list, refresh) = fingerList(refresh: { await gate.run() })
        list.fingerDown = true
        list.contentOffset.y = -(ListPullToRefresh.triggerDistance + 10)
        refresh.scrolled()
        await frames { gate.started == 1 }
        #expect(gate.started == 1)
        var target = list.contentOffset
        refresh.willEndDragging(targetContentOffset: &target)
        #expect(list.contentInset.top == ListPullToRefresh.slotHeight)
        // The finger takes the list again and holds it while the refresh ends: the inset stays under it.
        list.contentOffset.y = -150
        refresh.scrolled()
        gate.finish()
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(list.contentInset.top == ListPullToRefresh.slotHeight)
        // It lifts: the slot goes, and the bounce ends at the list's own top.
        var lift = list.contentOffset
        refresh.willEndDragging(targetContentOffset: &lift)
        #expect(list.contentInset.top == 0)
        #expect(lift.y == 0)
        window.isHidden = true
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
