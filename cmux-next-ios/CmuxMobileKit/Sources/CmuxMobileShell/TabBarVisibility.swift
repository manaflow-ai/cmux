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
                moving?(false)
            }
            if !accepted {
                // UIKit declined the callback (for example a nonanimated change). The next
                // layout reads the settled stack; do not spin main-queue retries meanwhile.
                following = false
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
            guard let tabs = tabBarController, let selected = tabs.selectedViewController,
                  isDescendant(of: selected) else { return }
            if !SwipeBackWholePage.legacy {
                if stack?.transitionCoordinator != nil {
                    follow(later: true)
                    // Keep root chrome out until completion, including programmatic Back.
                    if rootRequested { return }
                } else if rootRequested, let navigation = stack {
                    // SwiftUI's path can empty before UIKit starts its pop. A main-queue
                    // turn is not proof that the page has gone; wait for the actual stack.
                    guard navigation.viewControllers.count == 1 else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.rootRequested, !self.following,
                              let navigation = self.stack, navigation.transitionCoordinator == nil,
                              navigation.viewControllers.count == 1 else { return }
                        self.moving?(false)
                    }
                }
            }
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
