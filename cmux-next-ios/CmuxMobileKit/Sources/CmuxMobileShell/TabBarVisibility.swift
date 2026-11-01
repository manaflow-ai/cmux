#if os(iOS)
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
            .background(TabBarVisibilityEnforcer(hidden: !shows))
    }
}

/// Sets `UITabBarController.isTabBarHidden` to the shell's value for the tab
/// it sits in, when that tab is on screen: on each update, when the tab
/// appears, and on each layout (SwiftUI's own tab bar changes lay the tab out
/// again).
private struct TabBarVisibilityEnforcer: UIViewControllerRepresentable {
    let hidden: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hidden = hidden
        controller.apply(animated: !context.transaction.disablesAnimations)
    }

    final class Controller: UIViewController {
        var hidden = false

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
            apply(animated: false)
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
            let bar = tabs.tabBar
            guard tabs.isTabBarHidden != hidden || bar.accessibilityElementsHidden != hidden
                || bar.isUserInteractionEnabled == hidden else { return }
            tabBarLog.info("tab bar \(self.hidden ? "hidden" : "shown", privacy: .public) by the shell")
            if tabs.isTabBarHidden != hidden { tabs.setTabBarHidden(hidden, animated: animated && view.window != nil) }
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
