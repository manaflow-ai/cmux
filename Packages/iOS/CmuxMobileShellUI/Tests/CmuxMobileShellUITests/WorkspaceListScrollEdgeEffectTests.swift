#if os(iOS)
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// The workspace table is a `UIViewRepresentable`, so SwiftUI never registers
/// it with the enclosing bars. These tests pin the UIKit contract that makes
/// the soft scroll edge effect render: once hosted under a navigation and tab
/// bar controller, the table must be each container's content scroll view.
@MainActor
@Suite struct WorkspaceListScrollEdgeEffectTests {
    @Test func hostedTableDrivesNavigationAndTabBarScrollEdgeEffects() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = Fixture()

        #expect(fixture.content.contentScrollView(for: .top) === fixture.tableView)
        #expect(fixture.navigation.contentScrollView(for: .bottom) === fixture.tableView)
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
    /// A one-shot registration would strand the bottom edge unregistered.
    @Test func lateTabControllerAttachmentStillRegistersBottomEdge() throws {
        guard #available(iOS 26.0, *) else { return }
        let tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
        let content = UIViewController()
        content.view.addSubview(tableView)
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

    @Test func departingTableDoesNotClobberReplacementRegistration() throws {
        guard #available(iOS 26.0, *) else { return }
        let fixture = Fixture()
        let replacement = WorkspaceListUITableView(frame: .zero, style: .plain)

        fixture.content.view.addSubview(replacement)
        replacement.layoutIfNeeded()
        fixture.tableView.removeFromSuperview()

        #expect(fixture.content.contentScrollView(for: .top) === replacement)
    }

    /// Table hosted under `UITabBarController > UINavigationController >
    /// content`, mirroring the shell's TabView + NavigationStack chrome.
    @MainActor
    private struct Fixture {
        let tableView: WorkspaceListUITableView
        let content: UIViewController
        let navigation: UINavigationController
        let tabs: UITabBarController
        let window: UIWindow

        init() {
            tableView = WorkspaceListUITableView(frame: .zero, style: .plain)
            content = UIViewController()
            content.view.addSubview(tableView)
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
}
#endif
