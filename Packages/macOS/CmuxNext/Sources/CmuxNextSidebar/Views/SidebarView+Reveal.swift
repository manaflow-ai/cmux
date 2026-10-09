import AppKit
import CmuxNextDesign

// The pointer over the sidebar reveals its titlebar buttons, the spaces
// strip (`sidebar.spacesVisibility` hover, cx-5k3r) and, in minimal mode
// (`sidebar.minimalMode`, R54), the chosen pinned bands.
extension SidebarView {
    /// Fades the titlebar buttons in or out. Keyboard and VoiceOver users
    /// reach the same actions through the palette and the registry menus.
    /// Minimal mode's bands hide with the buttons; they stay in the view and
    /// accessibility tree (a fade, not isHidden), so VoiceOver still reaches
    /// their items. The footer's update pill is not in a band, so it stays
    /// visible: it is the only update notice. The top band's hairline fades
    /// with its band (Lawrence 2026-10-05).
    func setChromeRevealed(_ revealed: Bool) {
        let changed = revealed != isChromeRevealed
        isChromeRevealed = revealed
        for region in bandRegions { region.chromeRevealed = revealed }
        cardStack.revealed = revealed
        if changed { onChromeRevealChange?(revealed) }
        let alpha: CGFloat = revealed ? 1 : 0
        let mode = DesignSettings.shared.sidebarSections.minimalMode
        let above: CGFloat = revealed || !mode.hidesTop ? 1 : 0
        let below: CGFloat = revealed || !mode.hidesBottom ? 1 : 0
        let hidden = (top: above == 0, bottom: below == 0)
        guard changed || hidden != minimalHiddenBands else { return }
        minimalHiddenBands = hidden
        Motion.animate(.hover, in: self) {
            if changed {
                newButton.animator().alphaValue = alpha
                profileBar.animator().alphaValue = spacesAlpha(revealed: revealed)
            }
            aboveFade.animator().alphaValue = above
            belowFade.animator().alphaValue = belowBandAlpha(hiddenByMode: below == 0)
            footerRegion.animator().alphaValue = below
        }
        fadeLine(aboveLine, to: above)
    }

    /// The band below the list while minimal mode hides the bottom: faded,
    /// unless it holds All chats, whose rows stay and whose header alone
    /// fades with the hover (cx-xub5; only the footer row then hides).
    func belowBandAlpha(hiddenByMode: Bool) -> CGFloat {
        hiddenByMode && !belowRegion.appViews.values.contains(where: { $0 is SidebarHoverRevealing }) ? 0 : 1
    }

    /// After the bands change (All chats mounted or removed) the band below
    /// takes its alpha for the current hover state at once.
    func syncBelowBandAlpha() {
        guard !isChromeRevealed else { return }
        let alpha = belowBandAlpha(hiddenByMode: minimalHiddenBands.bottom)
        if belowFade.alphaValue != alpha { belowFade.alphaValue = alpha }
    }

    /// The spaces strip's opacity: shown while the sidebar is hovered, or
    /// always. A fade only: the strip stays in the accessibility tree.
    func spacesAlpha(revealed: Bool) -> CGFloat {
        revealed || spacesVisibility == .always ? 1 : 0
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
}
