import AppKit
import CmuxNextDesign
import QuartzCore

/// The brief highlight Reveal Workspace in Sidebar draws over the row it revealed: Flash Pane's gray ring
/// (`triggerFlash`, `Palette.focusRing`; a soft fill when borders are off) in the row's shape, one layer over the
/// list's rows. Two blinks (`Motion.flashAnimation`) while cmux animates loops; under Reduce Motion or with cmux
/// animations off it shows at once and goes at once, with no fade (``isAnimated`` false). The layer takes no
/// clicks and is no accessibility element; it removes itself when its animation ends.
struct SidebarRevealFlash {
    /// How long the highlight stays when it does not blink.
    static let steadyDuration: CFTimeInterval = 0.9

    /// The row the highlight stands over.
    let key: SidebarRowKey
    /// Whether it blinks (`Motion.sidebar.animatesLoops`), or shows and goes with no animation.
    let isAnimated: Bool
    /// The highlight, a sublayer of the list's layer while it shows.
    let layer: CALayer

    /// Whether the highlight is still over its row.
    var isShowing: Bool { layer.superlayer != nil }

    /// Draws the highlight over `frame` (list coordinates) of `list` and runs it once.
    @MainActor init(key: SidebarRowKey, frame: NSRect, in list: NSView, animated: Bool) {
        self.key = key
        isAnimated = animated
        layer = CALayer()
        layer.frame = frame
        layer.cornerRadius = SidebarStyle.rowCornerRadius
        layer.zPosition = 10 // over the row views' layers
        let color = list.performWithTheme { Palette.focusRing }
        if Borders.drawsLines {
            layer.borderWidth = 2
            layer.borderColor = color.cgColor
        } else {
            layer.backgroundColor = color.withAlphaComponent(0.18).cgColor
        }
        layer.opacity = 0
        guard let host = list.layer else { return }
        host.addSublayer(layer)
        let flash = animated ? Motion.sidebar.flashAnimation() : nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { [layer] in layer.removeFromSuperlayer() }
        layer.add(flash ?? Self.steady(), forKey: "revealFlash")
        CATransaction.commit()
    }

    /// Ends the highlight now (a second reveal replaces it).
    func remove() {
        layer.removeAllAnimations()
        layer.removeFromSuperlayer()
    }

    /// Fully shown for ``steadyDuration``, then gone: a hold from 1 to 1 (`Motion.hold`), so nothing fades.
    private static func steady() -> CAAnimation {
        let hold = Motion.hold("opacity", at: Float(1))
        hold.duration = steadyDuration
        hold.fillMode = .removed
        hold.isRemovedOnCompletion = true
        return hold
    }
}
