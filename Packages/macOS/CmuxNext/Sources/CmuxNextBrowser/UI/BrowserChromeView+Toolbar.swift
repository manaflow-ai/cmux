import AppKit
import CmuxNextDesign

// The toolbar row hides while the page is in pane fullscreen, or while the
// person hid it (Toggle Omnibar).
//
// A change commits once and moves on the render server, as Chrome's browser
// controls do (`cc/input/browser_controls_offset_manager.cc`: the controls
// slide as a compositor offset, the page does not lay out per frame): the row
// keeps its height and its pin moves it past the edge, one layout gives the
// page its rest size, and every row whose frame moved gets an additive
// `position.y` spring from where it was. A gap the moving page leaves shows
// the chrome's ground, the pane fill the page host also paints (Chrome's
// gutter, `content/browser/renderer_host/delegated_frame_host.h`).
extension BrowserChromeView {
    /// Toggle Omnibar (`palette.browserToggleOmnibar`): hides the address bar
    /// row of this tab, or shows it again. Pane fullscreen still hides it.
    public func toggleOmnibar() {
        isOmnibarHidden.toggle()
        setToolbarHidden(isOmnibarHidden || tab.state.isContentFullscreen)
    }

    /// How far past its edge the row sits: its own height while hidden, so hiding moves it, never resizes it.
    var hiddenToolbarOffset: CGFloat { isToolbarHidden ? currentToolbarHeight : 0 }

    func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        // Outside a window, or on a screenless or sleeping display, nothing draws the motion.
        let move = window != nil && Motion.canAnimate(in: self)
            ? MotionMove.spring(hidden ? .disappear : .appear, in: Motion.overlays) : nil
        let before: [ObjectIdentifier: NSRect] = move == nil ? [:] : Dictionary(uniqueKeysWithValues: subviews.map { (ObjectIdentifier($0), $0.frame) })
        let fade = toolbar.alphaValue - (hidden ? 0 : 1)
        isToolbarHidden = hidden
        toolbarToggles &+= 1
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        toolbar.alphaValue = hidden ? 0 : 1
        accessoryBar.isHidden = hidden
        applyAccessoryHeight()
        toolbarTopPin.constant = -hiddenToolbarOffset
        toolbarBottomPin.constant = hiddenToolbarOffset
        guard let move else {
            needsLayout = true
            return finishToolbarToggle(toolbarToggles)
        }
        // The one layout of this change: the page takes its rest size here, never per frame.
        layoutSubtreeIfNeeded()
        slideRows(from: before, fade: fade, move: move)
    }

    /// Adds the additive springs of one toggle in one transaction, so every row starts on the same
    /// frame; the transaction's completion is the landing.
    private func slideRows(from before: [ObjectIdentifier: NSRect], fade: CGFloat, move: MotionMove) {
        let toggle = toolbarToggles
        let key = "omnibarToggle.\(toggle)"
        CATransaction.begin()
        TransactionLanding { [weak self] in self?.finishToolbarToggle(toggle) }.install()
        for view in subviews {
            guard let layer = view.layer, let old = before[ObjectIdentifier(view)] else { continue }
            let shift = Self.rowShift(from: old, to: view.frame, flipped: isFlipped)
            guard shift != 0 else { continue }
            layer.add(move.additive("position.y", from: NSNumber(value: Double(shift)), to: NSNumber(value: 0)), forKey: key + ".y")
        }
        if fade != 0 {
            toolbar.layer?.add(move.additive("opacity", from: NSNumber(value: Float(fade)), to: NSNumber(value: 0)), forKey: key + ".opacity")
        }
        CATransaction.commit()
    }

    /// The `position.y` offset that shows a row where it was: a row that kept its height moves
    /// whole; one that resized (the page area) keeps its top edge, where page content is anchored.
    static func rowShift(from old: NSRect, to new: NSRect, flipped: Bool) -> CGFloat {
        (old.height == new.height || flipped) ? old.minY - new.minY : old.maxY - new.maxY
    }

    /// The landing of toggle number `toggle`: a hidden row stops drawing. A later toggle owns the row.
    func finishToolbarToggle(_ toggle: Int) {
        guard toggle == toolbarToggles, isToolbarHidden else { return }
        toolbar.isHidden = true
        separator.isHidden = true
    }
}

/// The seam from Core Animation's transaction completion to the main actor: `land` runs when every
/// animation added in the open transaction has finished.
@MainActor private struct TransactionLanding {
    let land: @MainActor () -> Void

    func install() {
        let land = land
        CATransaction.setCompletionBlock {
            // main-proof: CATransaction.h: the completion block is called on the main thread
            MainActor.assumeIsolated { land() }
        }
    }
}
