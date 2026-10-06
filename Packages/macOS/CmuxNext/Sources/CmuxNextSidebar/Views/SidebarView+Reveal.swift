import AppKit
import CmuxNextDesign

// The pointer over the sidebar reveals its titlebar buttons and, in
// minimal mode (`sidebar.minimalMode`, R54), the chosen pinned bands.
extension SidebarView {
    /// Fades the titlebar buttons in or out. Keyboard and VoiceOver users
    /// reach the same actions through the palette and the registry menus.
    /// Minimal mode's bands hide with the buttons; they stay in the view and
    /// accessibility tree (a fade, not isHidden), so VoiceOver still reaches
    /// their items. A band whose item carries a control (the update control
    /// on Settings) stays visible: it is the only update notice. Each band's
    /// hairline fades with its band (Lawrence 2026-10-05: "settings section
    /// border should fade if im not hovered").
    func setChromeRevealed(_ revealed: Bool) {
        let changed = revealed != isChromeRevealed
        isChromeRevealed = revealed
        cardStack.revealed = revealed
        if changed { onChromeRevealChange?(revealed) }
        let alpha: CGFloat = revealed ? 1 : 0
        let mode = DesignSettings.shared.sidebarSections.minimalMode
        let above: CGFloat = revealed || !mode.hidesTop || holdsAccessory(aboveRegion) ? 1 : 0
        let below: CGFloat = revealed || !mode.hidesBottom || holdsAccessory(belowRegion) ? 1 : 0
        let hidden = (top: above == 0, bottom: below == 0)
        guard changed || hidden != minimalHiddenBands else { return }
        minimalHiddenBands = hidden
        Motion.animate(.hover, in: self) {
            if changed { newButton.animator().alphaValue = alpha }
            aboveFade.animator().alphaValue = above
            belowFade.animator().alphaValue = below
        }
        fadeLine(aboveLine, to: above)
        fadeLine(belowLine, to: below)
    }

    /// A band hairline (a layer) to `alpha` with the hover fade, at once in a
    /// window with no screen.
    private func fadeLine(_ line: CALayer, to alpha: CGFloat) {
        let opacity = Float(alpha)
        guard line.opacity != opacity else { return }
        if Motion.canAnimate(in: self) {
            Motion.set(line, "opacity", to: opacity, fade: .hover)
        } else {
            Motion.transaction(nil) { line.opacity = opacity }
        }
    }

    /// Whether an item drawn in `region` carries a trailing control.
    private func holdsAccessory(_ region: SidebarRegionView) -> Bool {
        model.itemInfo.contains { $0.value.accessory != nil && region.itemView($0.key) != nil }
    }
}
