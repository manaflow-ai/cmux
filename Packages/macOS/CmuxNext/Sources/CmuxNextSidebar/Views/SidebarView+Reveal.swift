import AppKit
import CmuxNextDesign

// The pointer over the sidebar reveals, with Show Sidebar Controls Only on Hover (`sidebar.controlsOnHover`,
// Lawrence 2026-10-27), its New Workspace button, spaces strip, profile control and Search
// button; in Hide Bands Until Hover (`sidebar.minimalMode`, R54) the chosen pinned bands; and,
// with the thin scrollers' opt-in auto-hide, the scrollers. By default the controls always show.
extension SidebarViewComponents {
    /// Fades the hover chrome in or out (``SidebarChromeReveal``). Keyboard and VoiceOver users
    /// reach the same actions through the palette and the registry menus.
    /// Minimal mode's bands hide with the buttons; they stay in the view and
    /// accessibility tree (a fade), so VoiceOver still reaches their items. The
    /// footer's update pill stays visible (the only update notice). The top
    /// band's hairline fades with its band (Lawrence 2026-10-05).
    func setChromeRevealed(_ revealed: Bool) {
        // A menu the + or its chevron opened holds them revealed (and lit) until it closes, even
        // after the pointer leaves for the menu (Leo, 2026-10-26).
        let revealed = revealed || chromeMenuHolds > 0
        let changed = revealed != isChromeRevealed
        isChromeRevealed = revealed
        for region in bandRegions { region.chromeRevealed = revealed }
        if changed { onChromeRevealChange?(revealed) }
        // With the auto-hide (the default), the pointer arriving shows the thin scrollers a moment.
        if changed, revealed, SystemScrollers.thinScrollersAutoHide {
            for scroll: NSScrollView in [scrollView, aboveScroll, belowScroll] {
                (scroll.verticalScroller as? ThinScroller)?.flash()
            }
        }
        let target = chromeReveal(revealed: revealed)
        guard changed || target != appliedChromeReveal else { return }
        appliedChromeReveal = target
        minimalHiddenBands = (top: target.topBand == 0, bottom: target.bottomBand == 0)
        // A fade only, under Reduce Motion at once (the gate snaps): every piece keeps its frame.
        Motion.feedback.animate(.hover, in: self) {
            newButton.animator().alphaValue = target.newButton
            newWorkspaceOptionsButton.animator().alphaValue = target.newButton
            profileBar.animator().alphaValue = target.spaces
            aboveFade.animator().alphaValue = target.topBand
            belowFade.animator().alphaValue = belowRegion.restAlpha(hiddenByMode: target.bottomBand == 0)
            footerRegion.animator().alphaValue = target.footer
            searchButton.animator().alphaValue = target.footer
        }
        fadeLine(aboveLine, to: target.topBand)
    }

    /// A menu from a hover-revealed titlebar control opened (`true`) or closed (`false`). On the
    /// last close the reveal goes back to the pointer, which may have left meanwhile.
    func chromeMenuOpenChanged(_ open: Bool) {
        if open {
            chromeMenuHolds += 1
            setChromeRevealed(true)
        } else {
            chromeMenuHolds = max(0, chromeMenuHolds - 1)
            chromeHover?.refresh()
            setChromeRevealed(chromeHover?.isHovering ?? false)
        }
    }

    /// What each piece of the hover chrome shows with the pointer over the sidebar (`revealed`) or
    /// away, under the current settings (``SidebarChromeReveal``).
    func chromeReveal(revealed: Bool) -> SidebarChromeReveal {
        let sections = design.sidebarSections
        return SidebarChromeReveal(revealed: revealed, minimalMode: sections.minimalMode,
                                   controlsOnHover: sections.controlsOnHover, spacesVisibility: spacesVisibility)
    }

    /// The spaces strip's opacity: shown unless controls-on-hover hides it with the pointer away
    /// (``SidebarChromeReveal``). A fade only: the strip stays in the accessibility tree.
    func spacesAlpha(revealed: Bool) -> CGFloat {
        chromeReveal(revealed: revealed).spaces
    }

    /// A band hairline (a layer) to `alpha` with the hover fade, at once in a
    /// window with no screen.
    private func fadeLine(_ line: CALayer, to alpha: CGFloat) {
        let opacity = Float(alpha)
        guard line.opacity != opacity else { return }
        if Motion.canAnimate(in: self) {
            Motion.sidebar.set(line, "opacity", to: opacity, fade: .hover)
        } else {
            Motion.sidebar.transaction(nil) { line.opacity = opacity }
        }
    }
}
