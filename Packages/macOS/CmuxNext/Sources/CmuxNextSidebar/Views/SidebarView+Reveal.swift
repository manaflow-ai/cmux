import AppKit
import CmuxNextDesign

// The pointer over the sidebar reveals, in Minimal Mode (`sidebar.minimal`, user 2026-11-15) or with Show Sidebar
// Controls Only on Hover (`sidebar.controlsOnHover`, Lawrence 2026-10-27), its New Workspace button, spaces strip, profile control and Search
// button; in Hide Bands Until Hover (`sidebar.minimalMode`, R54) the chosen pinned bands; and,
// with the thin scrollers' opt-in auto-hide, the scrollers. By default the controls always show.
extension SidebarViewComponents {
    /// Fades the hover chrome in or out (``SidebarChromeReveal``). Keyboard and VoiceOver users
    /// reach the same actions through the palette and the registry menus.
    /// Minimal mode's bands hide with the buttons; they stay in the view and
    /// accessibility tree (a fade), so VoiceOver still reaches their items. The
    /// band's hairline fades with its band (Lawrence 2026-10-05). Minimal Mode
    /// also fades every other view but the content (``minimalChromeViews``),
    /// the cards included (user 2026-11-17).
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
            liveModeBadge?.animator().alphaValue = target.footer
            for view in minimalChromeViews { view.animator().alphaValue = target.rest }
        }
        fadeLine(aboveLine, to: target.topBand)
        // The faded footer's height goes to the list (or comes back) with the fade (``SidebarFooterCollapseMotion``).
        needsLayout = true
    }

    /// The height the list takes from the sidebar's bottom chrome now (``SidebarFooterCollapseMotion``): in
    /// Minimal Mode with the pointer away, the footer section when it and the spaces strip (which may share its
    /// row) are faded out, and the footer row of `footerRowHeight` too when no accessory (a status view) shows in
    /// it. 0 by default, with `sidebar.spacesVisibility` Always (what still shows keeps its room), and under the
    /// older Show Sidebar Controls Only on Hover alone, whose controls fade in place with nothing moving.
    func footerCollapseTarget(footerRowHeight: CGFloat, hasAccessories: Bool) -> CGFloat {
        guard design.sidebarSections.minimal else { return 0 }
        let reveal = appliedChromeReveal ?? chromeReveal(revealed: isChromeRevealed)
        guard reveal.footer == 0, reveal.spaces == 0 else { return 0 }
        return footerRegion.layoutResult.height + (hasAccessories ? 0 : footerRowHeight)
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
                                   controlsOnHover: sections.hidesControlsUntilHover, spacesVisibility: spacesVisibility,
                                   minimal: sections.minimal)
    }

    /// The views the Minimal Mode rule leaves to others: the content (the workspace list, the bands, the Priority
    /// view, edit mode's bar) and the controls with their own piece of ``SidebarChromeReveal``.
    private var revealExemptViews: [NSView] {
        [edgeFade, aboveFade, belowFade, priorityPanelView, footer, footerRegion, profileBar,
         newButton, newWorkspaceOptionsButton, searchButton] + [liveModeBadge, editBar].compactMap { $0 }
    }

    /// Every other view in the sidebar: the cards, the card stack, app health's line, the Update Available button,
    /// the Priority bell, the titlebar accessory, the needs-you tray. They fade together with ``SidebarChromeReveal/rest``
    /// (Minimal Mode, the pointer away). A rule over the sidebar's subviews, not a list of cards: a view added later
    /// hides by default.
    var minimalChromeViews: [NSView] {
        let exempt = Set(revealExemptViews.map(ObjectIdentifier.init))
        return subviews.filter { !exempt.contains(ObjectIdentifier($0)) }
    }

    /// Gives a view that joined the sidebar since the last reveal (a card that came, app health's line) the
    /// rest opacity at once, so a card that arrives with the pointer away arrives hidden: its own entrance
    /// (``SidebarCardTransition``) would otherwise draw it over the model value until it ends. Runs in `layout()`.
    func applyRestReveal() {
        let alpha = (appliedChromeReveal ?? chromeReveal(revealed: isChromeRevealed)).rest
        for view in minimalChromeViews where view.alphaValue != alpha {
            // A view in the middle of the hover fade is already headed there: its model value is the target.
            view.alphaValue = alpha
            if alpha == 0 { SidebarCardTransition().clear(view.layer) }
        }
    }

    /// How much of the card slot's room (the bottom cards and the card stack) the list takes now, as a fraction
    /// moving with the footer's collapse: 1 in Minimal Mode with the pointer away (the cards are faded out), 0 when
    /// they show. A fraction, not a height, so a card that comes or goes while hidden moves nothing.
    func cardCollapseFraction() -> CGFloat {
        let reveal = appliedChromeReveal ?? chromeReveal(revealed: isChromeRevealed)
        return cardCollapseMotion.height(toward: reveal.rest == 0 ? 1 : 0, in: self)
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
