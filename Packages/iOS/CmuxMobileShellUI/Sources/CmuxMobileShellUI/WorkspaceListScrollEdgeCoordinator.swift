#if os(iOS)
import UIKit

/// Registers the workspace table as the content scroll view of its enclosing
/// navigation and tab bar controllers so UIKit renders the scroll edge effect
/// under the top chrome (navigation bar + search drawer) and behind the tab
/// bar, App Store-style.
///
/// SwiftUI only drives bar scroll edge effects for its own scroll views. The
/// workspace list is a `UIViewRepresentable` `UITableView`, invisible to that
/// machinery, so without this registration the table's `.soft` top edge style
/// never renders and rows hard-clip at the search bar's bottom edge.
@MainActor
final class WorkspaceListScrollEdgeCoordinator {
    private weak var registeredScrollView: UIScrollView?
    private weak var navigationContentController: UIViewController?
    private weak var tabContentController: UIViewController?

    /// Re-resolves the bar-owning controllers for `scrollView` and registers
    /// it with them. Safe to call repeatedly; no-ops when nothing changed.
    /// Returns false when no enclosing bar controller is reachable yet (the
    /// view-controller parent chain may still be assembling), so the caller
    /// can retry after the next layout pass.
    @discardableResult
    func registerIfNeeded(for scrollView: UIScrollView) -> Bool {
        guard #available(iOS 26.0, *) else { return true }
        guard scrollView.window != nil else { return false }
        let navigationContent = Self.contentController(
            hosting: scrollView, inParentOfKind: UINavigationController.self
        )
        let tabContent = Self.contentController(
            hosting: scrollView, inParentOfKind: UITabBarController.self
        )
        guard navigationContent != nil || tabContent != nil else { return false }
        if navigationContent !== navigationContentController
            || tabContent !== tabContentController
            || scrollView !== registeredScrollView {
            unregister()
            registeredScrollView = scrollView
            navigationContentController = navigationContent
            tabContentController = tabContent
            navigationContent?.setContentScrollView(scrollView, for: .top)
            tabContent?.setContentScrollView(scrollView, for: .bottom)
        }
        return true
    }

    /// Clears this coordinator's registrations. A registration already taken
    /// over by a replacement table (same controller, different scroll view)
    /// is left intact.
    func unregister() {
        guard #available(iOS 26.0, *) else { return }
        if let controller = navigationContentController,
           let scrollView = registeredScrollView,
           controller.contentScrollView(for: .top) === scrollView {
            controller.setContentScrollView(nil, for: .top)
        }
        if let controller = tabContentController,
           let scrollView = registeredScrollView,
           controller.contentScrollView(for: .bottom) === scrollView {
            controller.setContentScrollView(nil, for: .bottom)
        }
        navigationContentController = nil
        tabContentController = nil
        registeredScrollView = nil
    }

    /// The last view controller on `view`'s parent chain before the first
    /// container of `Kind`: the content controller whose bars that container
    /// derives from `setContentScrollView(_:for:)` registrations.
    private static func contentController<Kind: UIViewController>(
        hosting view: UIView, inParentOfKind kind: Kind.Type
    ) -> UIViewController? {
        var responder: UIResponder? = view.next
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard var content = responder as? UIViewController else { return nil }
        while let parent = content.parent {
            if parent is Kind { return content }
            content = parent
        }
        return nil
    }
}
#endif
