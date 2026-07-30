#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

/// Owns the workspace table's relationship with UIKit navigation and tab bars.
///
/// The represented controller visually underlaps the bars so their native soft
/// effects have table pixels to process. Its parent remains fitted to the bars'
/// safe layout frame, which this controller forwards through
/// `additionalSafeAreaInsets`. UIKit remains the sole owner of the table's
/// adjusted insets and scroll position.
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
        updateChromeSafeAreaInsets()
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

    private func updateChromeSafeAreaInsets() {
        guard #available(iOS 26.0, *),
              let parent,
              let window = tableView.window else { return }

        let tableFrame = tableView.convert(tableView.bounds, to: window)
        let parentSafeFrame = parent.view.convert(
            parent.view.safeAreaLayoutGuide.layoutFrame,
            to: window
        )
        let desiredInsets = UIEdgeInsets(
            top: max(0, parentSafeFrame.minY - tableFrame.minY),
            left: 0,
            bottom: max(0, tableFrame.maxY - parentSafeFrame.maxY),
            right: 0
        )

        // Remove this controller's existing contribution to recover the
        // inherited safe area, then add only the delta needed to match the
        // enclosing bar owner's safe layout frame. This is stable across
        // repeated layout passes and never mutates the table's content offset.
        let inheritedTopInset = max(
            0,
            tableView.safeAreaInsets.top - additionalSafeAreaInsets.top
        )
        let inheritedBottomInset = max(
            0,
            tableView.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom
        )
        let nextAdditionalInsets = UIEdgeInsets(
            top: max(0, desiredInsets.top - inheritedTopInset),
            left: 0,
            bottom: max(0, desiredInsets.bottom - inheritedBottomInset),
            right: 0
        )
        guard nextAdditionalInsets != additionalSafeAreaInsets else { return }
        additionalSafeAreaInsets = nextAdditionalInsets
    }
}
#endif
