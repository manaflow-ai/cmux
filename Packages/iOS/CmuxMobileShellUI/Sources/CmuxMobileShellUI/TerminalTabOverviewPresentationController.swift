#if os(iOS)
import UIKit

/// One owner presents, dismisses and tears down both directions of the zoom.
@MainActor
final class TerminalTabOverviewPresentationController: UIViewController, UIViewControllerTransitioningDelegate {
    private var configuration: TerminalTabOverviewView?
    private var overview: TerminalTabOverviewViewController?
    private var transitionInProgress = false
    private var isStopped = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reconcilePresentation()
    }

    func update(_ configuration: TerminalTabOverviewView) {
        self.configuration = configuration
        overview?.update(
            workspaceName: configuration.workspaceName,
            items: configuration.items,
            canCloseTabs: configuration.canCloseTabs,
            onSelect: configuration.onSelect,
            onClose: configuration.onClose,
            onNewTerminal: configuration.onNewTerminal,
            onReorder: configuration.onReorder,
            onDone: configuration.onDone
        )
        // Complete SwiftUI's selection/layout transaction before capturing the
        // destination terminal. There is no animation timer or guessed delay.
        Task { @MainActor [weak self] in self?.reconcilePresentation() }
    }

    private func reconcilePresentation() {
        guard !isStopped, !transitionInProgress, viewIfLoaded?.window != nil,
              let configuration else { return }
        if configuration.isPresented, overview == nil {
            let overview = TerminalTabOverviewViewController(
                workspaceName: configuration.workspaceName,
                items: configuration.items,
                canCloseTabs: configuration.canCloseTabs,
                onSelect: configuration.onSelect,
                onClose: configuration.onClose,
                onNewTerminal: configuration.onNewTerminal,
                onReorder: configuration.onReorder,
                onDone: configuration.onDone
            )
            overview.modalPresentationStyle = .overFullScreen
            overview.transitioningDelegate = self
            self.overview = overview
            transitionInProgress = true
            present(overview, animated: true) { [weak self] in
                self?.transitionInProgress = false
                self?.reconcilePresentation()
            }
        } else if !configuration.isPresented, let overview {
            transitionInProgress = true
            overview.dismiss(animated: true) { [weak self] in
                self?.overview = nil
                self?.transitionInProgress = false
                self?.reconcilePresentation()
            }
        }
    }

    func stop() {
        isStopped = true
        configuration = nil
        overview?.stopTransitions()
        overview?.dismiss(animated: false)
        overview = nil
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        TerminalTabOverviewZoomTransition(isOpening: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        TerminalTabOverviewZoomTransition(isOpening: false)
    }
}
#endif
