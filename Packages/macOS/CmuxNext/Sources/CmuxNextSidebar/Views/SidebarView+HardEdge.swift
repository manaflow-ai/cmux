import AppKit
import CmuxNextDesign
import QuartzCore

/// Hard-edge chrome (`chrome.hardEdge`): the sidebar's + sits on a plate as tall as a tab pill and
/// cut like one, on the traffic lights' line the tabs center on, so the + reads as the first cell
/// of the one top row across the sidebar and the tabs. Off: no plate.
extension SidebarView {
    func layoutNewButtonPlate() {
        let style = HardEdge.current
        // A sublayer of the button's, so it fades and moves with the + (chrome reveal, minimal mode).
        guard style.isOn, let host = newButton.layer else {
            newButtonPlate.removeFromSuperlayer()
            return
        }
        if newButtonPlate.superlayer !== host { host.insertSublayer(newButtonPlate, at: 0) }
        let height = Metrics.tabHeight, button = newButton.bounds
        let rect = CGRect(x: button.midX - height / 2, y: button.midY - height / 2, width: height, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        newButtonPlate.frame = rect
        newButtonPlate.path = HardEdge.path(CGRect(origin: .zero, size: rect.size), cuts: .signature(HardEdge.fillCut), flipped: newButton.isFlipped)
        performWithTheme { newButtonPlate.fillColor = Palette.hoverFill.cgColor }
    }
}
