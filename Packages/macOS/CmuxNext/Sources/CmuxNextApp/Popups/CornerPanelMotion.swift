import AppKit
import CmuxNextDesign

/// Open and close of a panel pinned to its window's top-right corner with no
/// control under it (the notifications and feed panels, cx-f6i7): it appears
/// in one frame and fades/shrinks back into that corner on close. A reopen
/// during the close continues from what is on screen.
@MainActor
final class CornerPanelMotion {
    private var generation = 0
    /// The panel is fading out: it is on screen but no longer shown.
    private(set) var isClosing = false

    /// Orders `panel` front at its frame in one frame.
    func open(_ panel: NSWindow) {
        let reopening = isClosing && panel.isVisible
        isClosing = false
        generation += 1
        panel.ignoresMouseEvents = false
        if !reopening { panel.alphaValue = 0 }
        panel.orderFront(nil)
        panel.openPopup(pivot: Self.pivot(of: panel))
        // A reopen continues the close's scale, whose pivot was for the frame before.
        if reopening { resized(panel) }
    }

    /// `panel` changed size while it opens (rows arrived): the scale's pivot is baked into its
    /// transform, so the spring restarts from the scale on screen about the new corner.
    func resized(_ panel: NSWindow) {
        guard !isClosing, let layer = panel.contentView?.layer, layer.animation(forKey: "sublayerTransform") != nil,
              let shown = layer.presentation()?.sublayerTransform else { return }
        Motion.overlays.set(layer, "sublayerTransform", to: NSValue(caTransform3D: CATransform3DIdentity), spring: .popover,
                   from: NSValue(caTransform3D: Motion.scale(shown.m11, about: Self.pivot(of: panel), in: layer)))
    }

    /// Fades `panel` out into its top-right corner, then runs `done` (which
    /// orders it out) unless it reopened meanwhile.
    func close(_ panel: NSWindow, done: @escaping @MainActor () -> Void) {
        isClosing = true
        generation += 1
        let closing = generation
        // Clicks and keys during the fade reach the window under it.
        panel.ignoresMouseEvents = true
        panel.makeFirstResponder(nil)
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
