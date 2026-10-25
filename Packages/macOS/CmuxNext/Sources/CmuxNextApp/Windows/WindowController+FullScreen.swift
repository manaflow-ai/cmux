import AppKit
import CmuxNextBrowser
import CmuxNextDesign

// fullscreen-lag (user, 2026-10-19). A full screen enter or exit is one
// AppKit animation from the old size to the new one; the window takes the new
// size at its start. Nothing springs toward it (`Motion.isLiveResizing` holds
// for the transition), terminals send the daemon one grid at its end
// (`ResizeCoordinator`), hover cards close (their anchors move), and the top
// row lays out for where it rests: the traffic lights are away while the
// window leaves full screen (`ShellWindow.restingTrafficLights`), and once
// they are back every strip under them measures again.
extension WindowController {
    func windowWillEnterFullScreen(_ notification: Notification) {
        services.hoverCards.dismiss(.action)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransitionDidEnd()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        Motion.fullScreenTransitionFailed(window)
        fullScreenTransitionDidEnd()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        services.hoverCards.dismiss(.action)
        (window as? ShellWindow)?.isLeavingFullScreen = true
        pagePresentationWindowWillExitFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransitionDidEnd()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        Motion.fullScreenTransitionFailed(window)
        fullScreenTransitionDidEnd()
    }

    /// The lights are where they rest again (or gone, in full screen): the
    /// top row and every strip under it measure once more, in this turn.
    private func fullScreenTransitionDidEnd() {
        (window as? ShellWindow)?.isLeavingFullScreen = false
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        relayoutTopRowStrips()
    }
}

// Page fullscreen as in Chrome (a video's full screen button): a page that
// goes fullscreen in the window's only pane takes the whole screen. The
// window enters macOS full screen (unless it is there already) and its
// chrome (sidebar, right sidebar, title row, tab strip, the main pane's
// gutter and corners) steps aside; leaving puts back exactly what entering
// changed. With other panes on screen the page stays fullscreen in its pane.

extension AppServices {
    /// A browser page in `entry` entered or left element fullscreen.
    func pageContentFullscreenChanged(_ entry: BrowserEntry, on: Bool) {
        guard let controller = entry.chrome.window?.delegate as? WindowController else { return }
        if on { controller.presentPage(entry) } else { controller.endPagePresentation(of: entry.chrome) }
    }
}

extension WindowController {
    /// Gives `entry`'s fullscreen page the whole screen when its pane is the only one on screen.
    func presentPage(_ entry: BrowserEntry) {
        guard pagePresentation == nil, let window, let pane = lonePane(showing: entry.chrome) else { return }
        let entersFullScreen = !window.styleMask.contains(.fullScreen)
        pagePresentation = BrowserPagePresentation(chrome: entry.chrome, tab: entry.tab, pane: pane, entersWindowFullScreen: entersFullScreen)
        services.hoverCards.dismiss(.action)
        pane.presentsPage = true
        root.presentsPage = true
        if entersFullScreen { window.toggleFullScreen(nil) }
    }

    /// The page in `chrome` left fullscreen: the window's chrome comes back.
    func endPagePresentation(of chrome: BrowserChromeView) {
        guard pagePresentation?.chrome === chrome else { return }
        endPagePresentation()
    }

    /// Puts back what `presentPage` changed. Cleared first, so the full screen exit it starts is
    /// not read as the person's own (`windowWillExitFullScreen`).
    func endPagePresentation() {
        guard let presentation = pagePresentation else { return }
        pagePresentation = nil
        (presentation.pane as? PaneController)?.presentsPage = false
        root.presentsPage = false
        if presentation.entersWindowFullScreen, let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// The person left macOS full screen (the green button, the menu, its shortcut) while a page
    /// had the screen: the page leaves fullscreen too, as in Chrome.
    func pagePresentationWindowWillExitFullScreen() {
        guard let presentation = pagePresentation else { return }
        pagePresentation = nil
        (presentation.pane as? PaneController)?.presentsPage = false
        root.presentsPage = false
        presentation.tab?.exitContentFullscreen()
    }

    /// After a tab switch, a workspace switch or a pane resize (a split beside the page, a zoom
    /// out): a page no longer on screen leaves fullscreen (Chrome does on a tab switch); a page
    /// that gained a neighbor stays fullscreen in its pane, and the window's chrome comes back.
    func revalidatePagePresentation() {
        guard let presentation = pagePresentation else { return }
        guard let chrome = presentation.chrome, chrome.window === window, !chrome.isHiddenOrHasHiddenAncestor else {
            let tab = presentation.tab
            endPagePresentation()
            tab?.exitContentFullscreen()
            return
        }
        if let pane = presentation.pane, lonePane(showing: chrome) === pane { return }
        endPagePresentation()
    }

    /// The pane that shows `chrome`, when it is the only pane on screen in this window (no split
    /// beside it, no workspace shown beside this one).
    private func lonePane(showing chrome: BrowserChromeView) -> PaneController? {
        guard let content, !parked.values.contains(where: { !$0.drawsNothing }) else { return nil }
        var shown: PaneController?
        for pane in content.panes.values where pane.isVisible {
            guard shown == nil else { return nil }
            shown = pane
        }
        guard let shown, chrome.isDescendant(of: shown.view), !chrome.isHiddenOrHasHiddenAncestor else { return nil }
        return shown
    }
}
