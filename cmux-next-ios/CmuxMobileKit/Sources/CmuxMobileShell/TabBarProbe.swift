#if os(iOS)
import SwiftUI
import UIKit

#if DEBUG
/// UI tests only (`-cmux-mobile-tabbar-probe`): one accessibility element on
/// the window, `shell.tabbar.probe`, whose value is the root tab bar's real
/// state, read from UIKit at each query. A test reads this instead of the
/// accessibility tree's tab bar, which an accessibility-only hide removes
/// while the bar is still drawn.
///
/// "drawn" needs both: the tab bar controller does not hide it
/// (`isTabBarHidden`, which leaves its frame and view chain as they were), and
/// no view from the bar up to the window is hidden or transparent (SwiftUI's
/// own hide). Then the raw signals: `tbh` (isTabBarHidden), `ax` (VoiceOver
/// reaches it), `touch` (it takes touches), its frame in the window.
struct TabBarProbe: View {
    static let isEnabled = CommandLine.arguments.contains("-cmux-mobile-tabbar-probe")

    var body: some View {
        if Self.isEnabled { Installer().frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true) }
    }

    private struct Installer: UIViewRepresentable {
        func makeUIView(context: Context) -> InstallerView { InstallerView() }
        func updateUIView(_ view: InstallerView, context: Context) {}
    }

    /// Puts one probe on its window (above everything, no touches).
    final class InstallerView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !window.subviews.contains(where: { $0 is ProbeView }) else { return }
            let probe = ProbeView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
            window.addSubview(probe)
        }
    }

    final class ProbeView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = "shell.tabbar.probe"
            accessibilityLabel = "Tab bar probe"
            accessibilityTraits = .staticText
        }

        required init?(coder: NSCoder) { nil }

        override var accessibilityValue: String? {
            get { state }
            set {}
        }

        private var tabs: UITabBarController? {
            var queue: [UIViewController] = window?.rootViewController.map { [$0] } ?? []
            while !queue.isEmpty {
                let controller = queue.removeFirst()
                if let tabs = controller as? UITabBarController { return tabs }
                queue += controller.children
            }
            return nil
        }

        /// "drawn tbh=0 ax=1 touch=1 frame=(x,y,w,h)" or "gone …".
        private var state: String {
            guard let tabs, let window else { return "no-tab-bar" }
            let bar = tabs.tabBar
            guard bar.window != nil else { return "gone tbh=\(tabs.isTabBarHidden ? 1 : 0) ax=- touch=- frame=-" }
            let frame = bar.convert(bar.bounds, to: window)
            var chainShown = frame.intersects(window.bounds) && frame.height > 1
            var view: UIView? = bar
            while let current = view, chainShown {
                if current.isHidden || current.alpha < 0.01 { chainShown = false }
                view = current.superview
            }
            let drawn = chainShown && !tabs.isTabBarHidden
            return "\(drawn ? "drawn" : "gone") tbh=\(tabs.isTabBarHidden ? 1 : 0) chain=\(chainShown ? 1 : 0) "
                + "ax=\(bar.accessibilityElementsHidden ? 0 : 1) touch=\(bar.isUserInteractionEnabled ? 1 : 0) "
                + "frame=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))"
        }
    }
}
#endif
#endif
