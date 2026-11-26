#if os(iOS)
import CmuxMobileDesign
import OSLog
import SwiftUI
import UIKit

private let tabBarLog = Logger(subsystem: "dev.cmux.mobile", category: "tabbar")

/// One tab's root tab bar, shown or hidden by ``ShellModel/showsTabBar(on:)``:
/// the only thing that decides it. Applied by `ShellTabs` to each tab's
/// content, outside its navigation stack.
///
/// SwiftUI's `.toolbar(_:for: .tabBar)` alone is not enough. It drops the
/// hide when a tab is selected and pushed on in one update (a link, a
/// notification tap, the Feed's terminal events, the launch restore): the
/// pushed screen then shows over the bar. So the same value also goes to
/// the tab bar controller itself, every time SwiftUI could have changed it.
struct TabBarVisibility: ViewModifier {
    let shell: ShellModel
    let tab: RootTab

    func body(content: Content) -> some View {
        let shows = shell.showsTabBar(on: tab)
        content
            .toolbar(shows ? .visible : .hidden, for: .tabBar)
            .background(TabBarVisibilityEnforcer(hidden: !shows, rootRequested: shell.depth(of: tab) == 0, moving: { [shell, tab] moving in
                guard shell.stackMoving.contains(tab) != moving else { return }
                if moving { shell.stackMoving.insert(tab) } else { shell.stackMoving.remove(tab) }
            }))
    }
}

/// Sets `UITabBarController.isTabBarHidden` to the shell's value for the tab
/// it sits in, when that tab is on screen: on each update, when the tab
/// appears, and on each layout (SwiftUI's own tab bar changes lay the tab out
/// again).
private struct TabBarVisibilityEnforcer: UIViewControllerRepresentable {
    let hidden: Bool
    let rootRequested: Bool
    /// Told when the tab's navigation stack starts and stops a transition.
    let moving: (Bool) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hidden = hidden
        controller.rootRequested = rootRequested
        controller.moving = moving
        controller.apply(animated: !context.transaction.disablesAnimations)
    }

    final class Controller: UIViewController {
        var hidden = false
        var rootRequested = true
        var moving: ((Bool) -> Void)?
        private var following = false
        private var watched: [ObjectIdentifier] = []

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply(animated: false)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply(animated: false)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            watchStack()
            apply(animated: false)
        }

        /// The tab's own navigation stack (the one in the tab this sits in).
        private var stack: UINavigationController? {
            var tabRoot: UIViewController? = self
            while let controller = tabRoot, !(controller.parent is UITabBarController) { tabRoot = controller.parent }
            guard let tabRoot else { return nil }
            var queue: [UIViewController] = [tabRoot]
            while !queue.isEmpty {
                let controller = queue.removeFirst()
                if let navigation = controller as? UINavigationController { return navigation }
                queue += controller.children
            }
            return nil
        }

        /// A swipe back starts its transition before SwiftUI empties the path: follow it from
        /// its first frame, so the root chrome waits for the page to leave.
        private func watchStack() {
            guard let navigation = stack else { return }
            var gestures: [UIGestureRecognizer] = []
            if let pop = navigation.interactivePopGestureRecognizer { gestures.append(pop) }
            if #available(iOS 26.0, *), let content = navigation.interactiveContentPopGestureRecognizer { gestures.append(content) }
            for gesture in gestures where !watched.contains(ObjectIdentifier(gesture)) {
                gesture.addTarget(self, action: #selector(popGestureChanged(_:)))
                watched.append(ObjectIdentifier(gesture))
            }
        }

        @objc private func popGestureChanged(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed { follow() }
        }

        /// Reports the stack moving until its transition ends (finished or cancelled).
        /// `later`: called from a SwiftUI update, which must not change the shell's state.
        private func follow(later: Bool = false) {
            guard !SwipeBackWholePage.legacy, !following, let coordinator = stack?.transitionCoordinator else { return }
            following = true
            if later {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.following else { return }
                    self.moving?(true)
                }
            } else {
                moving?(true)
            }
            // Keep the reporting controller alive until the transition settles. Losing it
            // mid-pop must not leave the shell's root chrome permanently held.
            let accepted = coordinator.animate(alongsideTransition: nil) { [self] _ in
                following = false
                // Not a release by itself: this transition may be a push that a Back emptied
                // the path during, whose pop UIKit has not started yet (#56696 F2). The next
                // turn reads the stack as it settled and releases only at its root.
                DispatchQueue.main.async { [weak self] in self?.settle() }
            }
            if !accepted {
                // UIKit declined the callback (for example a nonanimated change): read the
                // stack once it settles, bounded by `RootHold.bound` (no unbounded retries).
                following = false
                DispatchQueue.main.async { [weak self] in self?.settle() }
            }
        }

        /// When the hold first waited on a pop UIKit had not started (nil: not waiting).
        private var waitingSince: Date?
        private var recheckScheduled = false

        /// Decide the tab's root hold from the stack as it is now (`RootHold.step`): follow a
        /// transition, wait a bounded time for a pop UIKit has not started, or release. Runs
        /// whether or not the tab is selected: a hidden tab's emptied path must not stay held
        /// until it is shown again (#56696 F1).
        private func settle() {
            guard !SwipeBackWholePage.legacy, !following else { return }
            let navigation = stack
            let waited = waitingSince.map { Date().timeIntervalSince($0) } ?? 0
            switch RootHold.step(transitioning: navigation?.transitionCoordinator != nil, rootRequested: rootRequested,
                                 depth: navigation?.viewControllers.count, waited: waited) {
            case .follow:
                waitingSince = nil
                follow(later: true)
            case .wait:
                if waitingSince == nil { waitingSince = Date() }
                guard !recheckScheduled else { return }
                // UIKit starts the pop within a frame or two of SwiftUI emptying the path, and
                // no layout or update is promised to reach this controller when it does (a
                // nonanimated pop): look again on a short timer until the bound.
                recheckScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + RootHold.recheck) { [weak self] in
                    guard let self else { return }
                    self.recheckScheduled = false
                    self.settle()
                }
            case .release:
                if waited >= RootHold.bound {
                    tabBarLog.error("root hold released at its bound: UIKit did not pop (depth \(navigation?.viewControllers.count ?? -1, privacy: .public))")
                }
                waitingSince = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.following else { return }
                    self.moving?(false)
                }
            }
        }

        /// Only the selected tab decides: a hidden tab's stack says nothing
        /// about the bar on screen.
        ///
        /// `setTabBarHidden` only moves the bar out of sight: its buttons stay
        /// in the accessibility tree (VoiceOver reached Home and Workspaces
        /// over a workspace) and at their frames. So a hidden bar is also
        /// hidden from accessibility and takes no touches, and a shown one
        /// gets both back; the three are set together every time.
        func apply(animated: Bool) {
            if !SwipeBackWholePage.legacy { settle() }
            guard let tabs = tabBarController, let selected = tabs.selectedViewController,
                  isDescendant(of: selected) else { return }
            // Keep root chrome out until the page has left, including programmatic Back.
            if !SwipeBackWholePage.legacy, rootRequested, stack?.transitionCoordinator != nil { return }
            let bar = tabs.tabBar
            guard tabs.isTabBarHidden != hidden || bar.accessibilityElementsHidden != hidden
                || bar.isUserInteractionEnabled == hidden else { return }
            tabBarLog.info("tab bar \(self.hidden ? "hidden" : "shown", privacy: .public) by the shell")
            // A page pushed over the tab: the bar goes at once instead of fading out over the
            // page coming in (it comes back after the page leaves, above).
            let pushing = hidden && !SwipeBackWholePage.legacy && stack?.transitionCoordinator != nil
            if tabs.isTabBarHidden != hidden { tabs.setTabBarHidden(hidden, animated: animated && !pushing && view.window != nil) }
            bar.accessibilityElementsHidden = hidden
            bar.isUserInteractionEnabled = !hidden
        }

        private func isDescendant(of ancestor: UIViewController) -> Bool {
            var current: UIViewController? = self
            while let controller = current {
                if controller === ancestor { return true }
                current = controller.parent
            }
            return false
        }
    }
}
#endif

import Foundation

/// What a tab's root hold does next (`TabBarVisibilityEnforcer`): the hold keeps the tab bar and
/// New Task out while a page leaves the tab's stack. A pure rule, so each way UIKit can (not) pop
/// is a unit test (`RootHoldTests`).
enum RootHoldStep: Equatable {
    /// A transition runs: hold until it completes, then decide again.
    case follow
    /// The path is empty but UIKit has not popped and no transition runs yet: hold, look again.
    case wait
    /// The stack is settled (or there is nothing to wait on): show the root chrome.
    case release
}

enum RootHold {
    /// The longest the hold waits for a pop UIKit never starts. Failing open (root chrome
    /// shown) beats a tab bar that never returns (#56696 F1).
    static let bound: TimeInterval = 1.0
    /// How often a waiting hold looks at the stack again.
    static let recheck: TimeInterval = 0.05

    /// `transitioning`: the stack has a transition coordinator. `rootRequested`: the tab's path
    /// is empty. `depth`: the stack's view controllers (nil: no stack found). `waited`: how long
    /// this hold has waited on a pop that has not started.
    static func step(transitioning: Bool, rootRequested: Bool, depth: Int?, waited: TimeInterval) -> RootHoldStep {
        if transitioning { return .follow }
        // A page is (again) pushed: a hold means nothing under it.
        guard rootRequested else { return .release }
        // No stack to wait on: nothing would ever release the hold.
        guard let depth, depth > 1 else { return .release }
        return waited < bound ? .wait : .release
    }
}
