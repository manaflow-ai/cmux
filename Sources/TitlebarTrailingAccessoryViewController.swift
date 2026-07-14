import AppKit
import SwiftUI

/// Hosts the per-window controls anchored to the trailing edge of the title bar.
@MainActor
final class TitlebarTrailingAccessoryViewController: NSTitlebarAccessoryViewController {
    let fileExplorerState: FileExplorerState
    private let hostingView: TitlebarTrailingAccessoryHostingView
    private var controlsAreVisible: Bool
    private var ownsReservation = true
    private var lastMeasuredWidth: CGFloat = 0

    init(
        fileExplorerState: FileExplorerState,
        isVisible: Bool,
        onToggleRightSidebar: @escaping () -> Void
    ) {
        self.fileExplorerState = fileExplorerState
        self.controlsAreVisible = isVisible
        let hostingView = TitlebarTrailingAccessoryHostingView(
            rootView: TitlebarTrailingControls(
                fileExplorerState: fileExplorerState,
                onToggleRightSidebar: onToggleRightSidebar
            )
        )
        self.hostingView = hostingView
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right

        hostingView.onMeasuredWidthChange = { [weak self] width in
            self?.handleMeasuredWidth(width)
        }
        hostingView.setContentHuggingPriority(.required, for: .horizontal)
        view = hostingView
        applyVisibility()
        hostingView.reportCurrentWidth(force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if controlsAreEffectivelyVisible {
            hostingView.reportCurrentWidth(force: true)
        }
    }

    override func viewWillDisappear() {
        publishReservationWidth(0)
        super.viewWillDisappear()
    }

    func setControlsVisible(_ isVisible: Bool) {
        controlsAreVisible = isVisible
        applyVisibility()
        if isVisible {
            hostingView.reportCurrentWidth(force: true)
        } else {
            publishReservationWidth(0)
        }
    }

    func prepareForRemoval() {
        guard ownsReservation else { return }
        controlsAreVisible = false
        applyVisibility()
        publishReservationWidth(0)
        ownsReservation = false
        hostingView.onMeasuredWidthChange = nil
    }

    private func handleMeasuredWidth(_ width: CGFloat) {
        if width > 0 {
            lastMeasuredWidth = width
        }
        publishReservationWidth(controlsAreEffectivelyVisible ? width : 0)
    }

    private func publishReservationWidth(_ width: CGFloat) {
        guard ownsReservation else { return }
        fileExplorerState.setTrailingTitlebarControlsReservationWidth(width)
    }

    private func applyVisibility() {
        isHidden = !controlsAreVisible
        view.isHidden = !controlsAreVisible
        view.alphaValue = controlsAreVisible ? 1 : 0
        if controlsAreVisible, lastMeasuredWidth > 0 {
            publishReservationWidth(lastMeasuredWidth)
        }
    }

    private var controlsAreEffectivelyVisible: Bool {
        !isHidden && !view.isHidden && view.alphaValue > 0
    }
}
