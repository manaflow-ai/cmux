import AppKit
import CmuxNextDesign

// The pointer over the sidebar reveals its titlebar buttons and, in
// minimal mode (`sidebar.minimalMode`, R54), the chosen pinned bands.
extension SidebarView {
    /// Fades the titlebar buttons in or out. Keyboard and VoiceOver users
    /// reach the same actions through the palette and the registry menus.
    /// Minimal mode's bands hide with the buttons; they stay in the view and
    /// accessibility tree (a fade, not isHidden), so VoiceOver still reaches
    /// their items.
    func setChromeRevealed(_ revealed: Bool) {
        let changed = revealed != isChromeRevealed
        isChromeRevealed = revealed
        cardStack.revealed = revealed
        let alpha: CGFloat = revealed ? 1 : 0
        let mode = DesignSettings.shared.sidebarSections.minimalMode
        let above: CGFloat = revealed || !mode.hidesTop ? 1 : 0
        let below: CGFloat = revealed || !mode.hidesBottom ? 1 : 0
        let hidden = (top: above == 0, bottom: below == 0)
        guard changed || hidden != minimalHiddenBands else { return }
        minimalHiddenBands = hidden
        Motion.animate(.hover) {
            if changed { newButton.animator().alphaValue = alpha }
            aboveFade.animator().alphaValue = above
            belowFade.animator().alphaValue = below
        }
    }
}
