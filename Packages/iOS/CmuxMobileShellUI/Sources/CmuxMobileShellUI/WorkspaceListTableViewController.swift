#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

/// Owns the workspace table's relationship with UIKit navigation and tab bars.
///
/// The represented controller visually underlaps the bars so their native soft
/// effects have table pixels to process. UIKit owns the table's safe area,
/// adjusted insets and scroll position; the only bridge is registering the
/// table as the bars' content scroll view, which SwiftUI cannot do for a
/// represented table.
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

    func presentWorkspaceCloseConfirmation(
        workspaceID: MobileWorkspacePreview.ID,
        sourceView: UIView,
        confirm: @escaping @MainActor () -> Void
    ) {
        guard presentedViewController == nil,
              sourceView.window != nil else { return }

        let alert = UIAlertController(
            title: L10n.string(
                "mobile.workspace.delete.confirmTitle",
                defaultValue: "Delete Workspace?"
            ),
            message: L10n.string(
                "mobile.workspace.delete.confirmMessage",
                defaultValue: "This will close the workspace on your Mac."
            ),
            preferredStyle: .actionSheet
        )
        alert.view.accessibilityIdentifier =
            "MobileWorkspaceDeleteConfirmation-\(workspaceID.rawValue)"
        alert.addAction(
            UIAlertAction(
                title: L10n.string(
                    "mobile.workspace.delete.confirmAction",
                    defaultValue: "Delete"
                ),
                style: .destructive
            ) { _ in
                MainActor.assumeIsolated {
                    confirm()
                }
            }
        )
        alert.addAction(
            UIAlertAction(
                title: L10n.string("mobile.common.cancel", defaultValue: "Cancel"),
                style: .cancel
            )
        )
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sourceView
            popover.sourceRect = sourceView.bounds
        }
        present(alert, animated: true)
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
