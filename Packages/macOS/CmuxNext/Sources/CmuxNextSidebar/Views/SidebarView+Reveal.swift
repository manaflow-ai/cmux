import AppKit
import CmuxNextDesign

// The pointer over the sidebar reveals its titlebar buttons and, in
// minimal mode (`sidebar.minimalMode`, R54), the chosen pinned bands.
extension SidebarView {
    /// Keeps titlebar and pinned section chrome mounted. Keyboard and
    /// VoiceOver users reach the same actions through the palette and menus.
    func setChromeRevealed(_ revealed: Bool) {
        let changed = revealed != isChromeRevealed
        isChromeRevealed = revealed
        cardStack.revealed = revealed
        let alpha: CGFloat = 1
        // Section chrome, including the Settings footer row, stays present.
        // Hover only affects paint and transient content inside the regions.
        let above: CGFloat = 1
        let below: CGFloat = 1
        let hidden = (top: false, bottom: false)
        guard changed || hidden != minimalHiddenBands else { return }
        minimalHiddenBands = hidden
        Motion.animate(.hover, in: self) {
            newButton.animator().alphaValue = alpha
            aboveFade.animator().alphaValue = above
            belowFade.animator().alphaValue = below
        }
    }

    /// Whether an item drawn in `region` carries a trailing control.
    private func holdsAccessory(_ region: SidebarRegionView) -> Bool {
        model.itemInfo.contains { $0.value.accessory != nil && region.itemView($0.key) != nil }
    }
}
