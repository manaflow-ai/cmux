import Foundation

/// Holds the find-window model for a window's command palette overlay.
///
/// The overlay state decides which panel shows. The model is only handed out while
/// that state is `.findTmuxWindow`, and it is closed as soon as any other overlay
/// takes over, whichever path replaced it.
@MainActor
struct RemoteTmuxFindWindowSlot {
    private var model: RemoteTmuxFindWindowModel?
    /// Opens the find bar after this window's jumps, so a newer jump replaces one
    /// still loading history. It outlives each model, which closes on the jump.
    let jumper = RemoteTmuxFindWindowJumper()

    /// The model, when find-window is the overlay showing.
    func activeModel(in state: CommandPaletteOverlayState) -> RemoteTmuxFindWindowModel? {
        state == .findTmuxWindow ? model : nil
    }

    /// Holds `model`, closing any earlier one.
    mutating func present(_ model: RemoteTmuxFindWindowModel) {
        if self.model !== model { self.model?.close() }
        self.model = model
    }

    /// Closes and drops the model when the overlay is no longer find-window.
    mutating func overlayDidChange(to state: CommandPaletteOverlayState) {
        guard state != .findTmuxWindow, let model else { return }
        model.close()
        self.model = nil
    }
}
