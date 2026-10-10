import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextUpdater

/// `app.shareCmux` (palette, Help menu, the "cmux Updated!" card's Share
/// cmux row; cx-7py7): the Share cmux modal, centered over the active
/// window with a scrim (the app host without a window). One at a time;
/// the x and Escape close it.
@MainActor
enum ShareCmuxPresenter {
    /// The modal on screen, if any (`debug.updater {action: "share-copy"}`).
    private(set) static weak var shown: ShareCmuxView?

    /// Shows the modal. A run that may not change the view (automation
    /// without `focus`) shows nothing: the modal takes the keyboard.
    static func present(_ services: AppServices) {
        guard ActionRunScope.viewChangeAllowed(), shown == nil else { return }
        let host = services.windows.active?.window.map(WindowOverlayHost.host(for:)) ?? WindowOverlayHost.appHost()
        let view = ShareCmuxView()
        let handle = host.present(view, options: .dialog())
        view.onClose = { [weak handle] in handle?.dismiss() }
        handle.onDismiss = { shown = nil }
        shown = view
        // The overlay's focus trap starts on its first control in view order (the x); Copy Link goes first.
        view.focusCopyLink()
    }
}
