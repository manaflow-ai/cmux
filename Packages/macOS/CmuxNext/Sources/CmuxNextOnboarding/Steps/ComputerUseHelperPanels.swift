import AppKit
import CmuxNextDesign

/// The native half of the Computer Use window, beside its page: Allow docks `HelperDragPanel` to
/// System Settings while the grant is missing, and the window comes back to the front when a grant
/// lands or the panel's back button closes it (`ComputerUseStepModel.comebacks`). The page draws
/// the rows; this owns only the panel and the window's return.
@MainActor
final class ComputerUseHelperPanels {
    /// Runs after the window comes back in front (the controller focuses its page).
    var onForward: (() -> Void)?
    private let model: ComputerUseStepModel
    private weak var window: NSWindow?
    private var panel: HelperDragPanel?
    private var panelPane: ComputerUsePermissionPane?
    private var seenComebacks: Int
    private var loop: RenderLoop?

    init(model: ComputerUseStepModel, window: NSWindow) {
        self.model = model
        self.window = window
        seenComebacks = model.comebacks
        // Closing the window stops the step (windowWillClose, OnboardingModel.leave): the panel goes now.
        model.onStop = { [weak self] in self?.hidePanel() }
        loop = RenderLoop { [weak self] in self?.render() }
    }

    private func render() {
        if model.comebacks != seenComebacks {
            seenComebacks = model.comebacks
            bringForward()
        }
        let helping = model.helping
        guard helping != panelPane else { return }
        panelPane = helping
        panel?.orderOut(nil)
        panel = nil
        guard let helping, let window, let url = model.helperAppURL else { return }
        let next = HelperDragPanel(appURL: url, pane: helping,
                                   onBack: { [weak model] in model?.dismissHelper() },
                                   onDrop: { [weak model] in model?.helperDropped() })
        next.show(on: window.screen)
        panel = next
    }

    /// A grant landed while System Settings was in front: the window comes back.
    private func bringForward() {
        guard let window else { return }
        window.orderFrontRegardless()
        guard !WindowPlacement.noActivate else { return }
        NSApp.activate()
        window.makeKey()
        // The page takes the keys again (a Chromium page's own child window, not the host window).
        onForward?()
    }

    func hidePanel() {
        loop?.cancel()
        panel?.orderOut(nil)
        panel = nil
        panelPane = nil
    }
}
