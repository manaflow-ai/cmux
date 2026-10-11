import AppKit
import CmuxNextDesign

/// Open and close of a panel pinned to its window's top-right corner with no
/// control under it (the notifications and feed panels, cx-f6i7): it grows
/// out of that corner and shrinks back into it (`NSWindow.openPopup`), so it
/// never pops in or vanishes. A reopen during the close continues from what
/// is on screen. Reduce Motion keeps the fades only.
@MainActor
final class CornerPanelMotion {
    private var generation = 0
    /// The panel is fading out: it is on screen but no longer shown.
    private(set) var isClosing = false

    /// Orders `panel` front at its frame, growing out of its top-right corner.
    func open(_ panel: NSWindow) {
        let reopening = isClosing && panel.isVisible
        isClosing = false
        generation += 1
        panel.ignoresMouseEvents = false
        if !reopening { panel.alphaValue = 0 }
        panel.orderFront(nil)
        panel.openPopup(pivot: Self.pivot(of: panel))
    }

    /// Fades `panel` out into its top-right corner, then runs `done` (which
    /// orders it out) unless it reopened meanwhile.
    func close(_ panel: NSWindow, done: @escaping @MainActor () -> Void) {
        isClosing = true
        generation += 1
        let closing = generation
        // Clicks during the fade reach the window under it.
        panel.ignoresMouseEvents = true
        panel.closePopup(pivot: Self.pivot(of: panel)) { [weak self, weak panel] in
            guard let self, self.isClosing, self.generation == closing else { return }
            self.isClosing = false
            done()
            panel?.resetPopupScale()
        }
    }

    private static func pivot(of panel: NSWindow) -> CGPoint {
        panel.popupPivot(toward: CGRect(x: panel.frame.maxX, y: panel.frame.maxY, width: 0, height: 0))
    }
}
