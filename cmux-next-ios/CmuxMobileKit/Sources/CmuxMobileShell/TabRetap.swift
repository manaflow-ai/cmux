#if os(iOS)
import SwiftUI
import UIKit

/// A tap on the tab that is already selected, at its root, scrolls that tab's list to its top
/// (the iOS Mail pattern; ``ShellModel/retapped(_:)`` decides between this and popping to the root).
/// Applied by `ShellTabs` to each tab's content, outside its navigation stack. The Feed takes the
/// request itself (`FeedScreen`), so its "N new" pill and jump state follow.
struct TabRetapScroll: ViewModifier {
    let shell: ShellModel
    let tab: RootTab

    func body(content: Content) -> some View {
        content.background(TabTopScroller(request: shell.topRequests[tab, default: 0]))
    }
}

/// Scrolls the tab it sits in to its top on each new `request`: the tab's main vertical scroll view
/// (the one a status bar tap scrolls), whatever draws it (a SwiftUI `List`, a collection view, a
/// loading skeleton), so each screen needs no scroll plumbing of its own.
private struct TabTopScroller: UIViewRepresentable {
    let request: Int

    final class Coordinator {
        var handled: Int
        init(handled: Int) { self.handled = handled }
    }

    func makeCoordinator() -> Coordinator { Coordinator(handled: request) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.handled != request else { return }
        context.coordinator.handled = request
        guard let list = Self.mainScrollView(around: view) else { return }
        let top = CGPoint(x: list.contentOffset.x, y: -list.adjustedContentInset.top)
        guard abs(list.contentOffset.y - top.y) > 0.25 else { return }
        list.setContentOffset(top, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    /// The largest vertical scroll view on screen in the tab around `view`: the nearest ancestor
    /// that holds one, never above the tab bar controller's own view (other tabs are not searched).
    private static func mainScrollView(around view: UIView) -> UIScrollView? {
        var ancestor = view.superview
        while let current = ancestor, !(current.next is UITabBarController) {
            var best: UIScrollView?
            var queue = [current]
            while let candidate = queue.popLast() {
                guard !candidate.isHidden, candidate.alpha > 0 else { continue }
                if let scroll = candidate as? UIScrollView {
                    if scroll.scrollsToTop, scroll.isScrollEnabled, scroll.window != nil,
                       scroll.contentSize.height > scroll.contentSize.width || scroll.alwaysBounceVertical,
                       scroll.bounds.width * scroll.bounds.height > (best.map { $0.bounds.width * $0.bounds.height } ?? 0) {
                        best = scroll
                    }
                    // A scroll view's own subviews are its content: nothing to scroll to the top there.
                    continue
                }
                queue.append(contentsOf: candidate.subviews)
            }
            if let best { return best }
            ancestor = current.superview
        }
        return nil
    }
}
#endif
