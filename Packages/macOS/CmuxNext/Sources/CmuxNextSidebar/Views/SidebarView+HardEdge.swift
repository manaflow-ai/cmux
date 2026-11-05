import AppKit
import CmuxNextDesign
import QuartzCore

/// Hard-edge chrome (`chrome.hardEdge`): the sidebar's + takes a tab pill's frame, the same top,
/// height and 45° cuts as the first tab's, so the + reads as the first cell of the one top row
/// across the sidebar and the tabs. Off: today's frame on the traffic lights' line.
extension SidebarView {
    /// The top row's pill in this view's coordinates: where the top tab strip puts its pills
    /// (`WindowTitlebar.cardTopInset` and `PaneChromeMetrics`); nil when hard-edge chrome is off.
    func hardEdgePillRect(trailingX: CGFloat) -> NSRect? {
        guard HardEdge.current.isOn, let window, let root = window.contentView else { return nil }
        let scale = window.backingScaleFactor, chrome = PaneChromeMetrics.current
        let cardTop = WindowTitlebar.cardTopInset(of: root, minimal: DesignSettings.shared.titlebar == .minimal, gutter: Metrics.mainPaneGutter)
        let top = cardTop + chrome.tabGap(scale: scale) // from the window's top edge
        let side = Metrics.tabHeight
        let windowY = root.bounds.maxY - top - side
        let local = convert(root.convert(NSRect(x: 0, y: windowY, width: side, height: side), to: nil), from: nil)
        return NSRect(x: trailingX - side, y: local.minY, width: side, height: side)
    }
}

extension SidebarIconButton {
    /// Cuts the fill like a tab pill under hard-edge chrome (`cutsHardEdge`); square where not cut.
    func applyHardEdgeCut() {
        guard let layer else { return }
        guard cutsHardEdge, HardEdge.current.isOn else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        layer.cornerRadius = 0
        let mask = layer.mask as? CAShapeLayer ?? CAShapeLayer()
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        mask.frame = bounds
        mask.path = HardEdge.path(bounds, cuts: .fill(HardEdge.fillCut), flipped: isFlipped)
        if layer.mask !== mask { layer.mask = mask }
    }
}
