#if os(iOS)
import UIKit

/// Owns the workspace table's relationship with UIKit navigation and tab bars.
///
/// UIKit remains the sole owner of adjusted insets and scroll position. This
/// controller only registers which scroll view drives each native edge effect.
@MainActor
final class WorkspaceListTableViewController: UIViewController {
    let tableView = WorkspaceListUITableView(frame: .zero, style: .plain)

    private let scrollEdgeCoordinator = WorkspaceListScrollEdgeCoordinator()

    override func loadView() {
        view = tableView
        tableView.scrollEdgeRegistrationNeedsUpdate = { [weak self] in
            self?.updateScrollEdgeRegistration()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateScrollEdgeRegistration()
    }

    func detach() {
        tableView.scrollEdgeRegistrationNeedsUpdate = nil
        scrollEdgeCoordinator.unregister()
    }

    private func updateScrollEdgeRegistration() {
        if tableView.window == nil {
            scrollEdgeCoordinator.unregister()
        } else {
            scrollEdgeCoordinator.registerIfNeeded(for: tableView)
        }
    }
}
#endif
