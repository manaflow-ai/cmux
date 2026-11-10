public import AppKit
import CmuxNextDesign

// The sidebar's width slide moves its panel, so its titlebar row's controls (the + and its chooser,
// the Priority bell, the accessory) travel with the panel's edge. The window's toolbar band (toggle,
// Back, Forward) closes up toward the traffic lights over the same frames, and the row used to slide
// over the band and the traffic lights to the window's edge in a few frames: the + read as jumping to
// the left. The row now stops at the band's trailing edge on screen and rides it while the sidebar's
// edge closes over it, so a collapse slides the + left into the band and the clip takes it there; an
// expand runs the same frames backwards. At rest the floor is the full band's edge, where the row
// already starts (`titlebarLeadingReserve`), so nothing moves.
extension SidebarViewComponents {
    /// The row's controls that keep clear of the toolbar band.
    var titlebarRowControls: [NSView] {
        [newButton as NSView?, newWorkspaceOptionsButton, priorityButton, titlebarAccessory].compactMap { $0 }.filter { !$0.isHidden }
    }

    /// Moves the row's controls right by just enough that the leftmost starts at
    /// `titlebarControlsFloor` (window x), and back once the floor no longer reaches them. Runs in
    /// this view's layout and in the container's, which runs every frame of the width slide and
    /// passes this view's x in the window (`originInWindow`) since the panel's frame is set after it.
    func keepTitlebarControlsClearOfBand(originInWindow: CGFloat? = nil) {
        let controls = titlebarRowControls
        guard let restingMinX = controls.map({ $0.frame.minX - titlebarRowShift }).min() else {
            titlebarRowShift = 0
            return
        }
        var shift: CGFloat = 0
        if let floor = titlebarControlsFloor, window != nil {
            let local = originInWindow.map { floor - $0 } ?? convert(CGPoint(x: floor, y: 0), from: nil).x
            shift = max(0, local - restingMinX)
            let pixels = max(window?.backingScaleFactor ?? 2, 1)
            shift = (shift * pixels).rounded() / pixels
        }
        let delta = shift - titlebarRowShift
        guard delta != 0 else { return }
        titlebarRowShift = shift
        for control in controls { control.frame.origin.x += delta }
    }
}

extension SidebarView {
    /// The window root's titlebar row, each layout: whether the traffic lights are over this header,
    /// where the row may start at rest (after the full band), and the band's edge on screen now.
    public func followToolbarBand(windowControls: Bool, reserve: CGFloat, edgeInWindow: CGFloat?) {
        (headerHasWindowControls, titlebarLeadingReserve, titlebarControlsFloor) = (windowControls, reserve, edgeInWindow)
    }
}
