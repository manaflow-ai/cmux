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

    /// Re-resolves the bar-owning controllers for `scrollView` and claims any
    /// edge whose registration is vacant. Called on every layout pass: the
    /// controller chain can assemble incrementally (navigation controller
    /// before tab controller) or reparent without the window changing, so a
    /// one-shot registration would strand a partially registered edge.
    ///
    /// Ownership arbitration: an edge is claimed only when its current
    /// registration is nil or held by a detached scroll view. A different
    /// LIVE table keeps its registration, so coexisting tables (SwiftUI
    /// transition overlap) never steal from each other; when the owner
    /// departs it clears the edge and the survivor reclaims on its next
    /// layout pass. When nothing changed this is a no-op costing a short
    /// parent walk and two getter comparisons.
    func registerIfNeeded(for scrollView: UIScrollView) {
        guard #available(iOS 26.0, *) else { return }
        guard scrollView.window != nil else { return }
        let navigationContent = Self.contentController(
            hosting: scrollView, inParentOfKind: UINavigationController.self
        )
        let tabContent = Self.contentController(
            hosting: scrollView, inParentOfKind: UITabBarController.self
        )
        guard navigationContent != nil || tabContent != nil else { return }

        if navigationContent !== navigationContentController
            || scrollView !== registeredScrollView {
            clearEdgeIfOwned(on: navigationContentController, edge: .top)
        }
        if tabContent !== tabContentController || scrollView !== registeredScrollView {
            clearEdgeIfOwned(on: tabContentController, edge: .bottom)
        }
        registeredScrollView = scrollView
        navigationContentController = navigationContent
        tabContentController = tabContent

        if let navigationContent,
           Self.canClaim(current: navigationContent.contentScrollView(for: .top),
                         claimant: scrollView) {
            navigationContent.setContentScrollView(scrollView, for: .top)
        }
        if let tabContent,
           Self.canClaim(current: tabContent.contentScrollView(for: .bottom),
                         claimant: scrollView) {
            tabContent.setContentScrollView(scrollView, for: .bottom)
        }
    }

    /// Clears this coordinator's registrations. A registration held by
    /// another table (same controller, different scroll view) is left intact.
    func unregister() {
        guard #available(iOS 26.0, *) else { return }
        clearEdgeIfOwned(on: navigationContentController, edge: .top)
        clearEdgeIfOwned(on: tabContentController, edge: .bottom)
        navigationContentController = nil
        tabContentController = nil
        registeredScrollView = nil
    }

    private func clearEdgeIfOwned(on controller: UIViewController?, edge: NSDirectionalRectEdge) {
        guard let controller,
              let scrollView = registeredScrollView,
              controller.contentScrollView(for: edge) === scrollView else { return }
        controller.setContentScrollView(nil, for: edge)
        // Deterministic handoff: a waiting table stood down while this one
        // owned the edge, and UIKit does not guarantee it another layout pass
        // after this teardown. Nudge it so its next pass claims the vacancy;
        // the woken table still runs its own claim arbitration.
        if let waiting = Self.firstWorkspaceTable(
            under: controller.viewIfLoaded, excluding: scrollView
        ) {
            waiting.setNeedsLayout()
        }
    }

    private static func firstWorkspaceTable(
        under view: UIView?, excluding departing: UIScrollView
    ) -> WorkspaceListUITableView? {
        guard let view else { return nil }
        if let table = view as? WorkspaceListUITableView, table !== departing {
            return table
        }
        for subview in view.subviews {
            if let found = firstWorkspaceTable(under: subview, excluding: departing) {
                return found
            }
        }
        return nil
    }

    /// Vacant (nil) and stale (holder departed its window without clearing,
    /// e.g. deallocated mid-transition) registrations are claimable. An edge
    /// already held by the claimant needs no re-set, and a different live
    /// scroll view keeps ownership.
    private static func canClaim(current: UIScrollView?, claimant: UIScrollView) -> Bool {
        guard let current else { return true }
        if current === claimant { return false }
        return current.window == nil
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
