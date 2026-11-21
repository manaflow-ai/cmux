import AppKit
import CmuxNextBrowser
import CmuxNextDesign

// fullscreen-lag (user, 2026-10-19). A full screen enter or exit is one
// AppKit animation from the old size to the new one; the window takes the new
// size at its start. Nothing in it springs toward it (`Motion.isLiveResizing(window)`
// holds for the transition), terminals send the daemon one grid at its end
// (`ResizeCoordinator`), hover cards close (their anchors move), and the top
// row lays out for where it rests: the traffic lights are away while the
// window leaves full screen (`ShellWindow.restingTrafficLights`), and once
// they are back every strip under them measures again.
extension WindowController {
    func windowWillEnterFullScreen(_ notification: Notification) {
        services.hoverCards.dismiss(.action)
        isEnteringFullScreen = true
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransitionDidEnd()
        pageFullScreenEnterDidEnd()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        Motion.fullScreenTransitionFailed(window)
        fullScreenTransitionDidEnd()
        pageFullScreenEnterDidEnd()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        services.hoverCards.dismiss(.action)
        (window as? ShellWindow)?.isLeavingFullScreen = true
        pagePresentationWindowWillExitFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransitionDidEnd()
        // A page went fullscreen while the window was leaving full screen: it enters again now.
        if pagePresentation?.entersWindowFullScreen == true, let window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        Motion.fullScreenTransitionFailed(window)
        fullScreenTransitionDidEnd()
    }

    /// The lights are where they rest again (or gone, in full screen): the
    /// top row and every strip under it measure once more, in this turn.
    private func fullScreenTransitionDidEnd() {
        (window as? ShellWindow)?.isLeavingFullScreen = false
        root.applyMainPane() // a fullscreen window has no lit rim to leave room for (`Metrics.windowEdgeInset`)
        root.layoutSubtreeIfNeeded()
        relayoutTopRowStrips()
    }
}

// Page fullscreen as in Chrome (a video's full screen button): a fullscreen page takes the whole
// screen. The window enters macOS full screen (unless it is there already), its chrome (sidebar,
// right sidebar, title row, tab strip, gutter, corners) steps aside and panes beside the page's hide
// as under pane zoom (`WorkspaceContentController.presentedPane`); leaving puts back what entering
// changed. A chat beside a video kept it in its pane (user, 2026-11-09); only a workspace shown
// beside this one still does.

extension AppServices {
    /// A browser page in `entry` entered or left element fullscreen.
    func pageContentFullscreenChanged(_ entry: BrowserEntry, on: Bool) {
        guard let chrome = entry.chrome, let controller = chrome.window?.delegate as? WindowController else { return }
        if on { controller.presentPage(entry) } else { controller.endPagePresentation(of: chrome) }
    }
}

extension WindowController {
    /// Gives `entry`'s fullscreen page the whole screen: its pane alone fills the window.
    func presentPage(_ entry: BrowserEntry) {
        guard pagePresentation == nil, let window, let chrome = entry.chrome, let pane = shownPane(showing: chrome) else { return }
        let leaving = (window as? ShellWindow)?.isLeavingFullScreen == true
        // The full screen is the page's when the window is not there, is on its way out, or entered
        // for an earlier page whose exit waits for the enter to end (`pageFullScreenExitPending`).
        let entersFullScreen = !window.styleMask.contains(.fullScreen) || leaving || pageFullScreenExitPending
        pageFullScreenExitPending = false
        pagePresentation = BrowserPagePresentation(chrome: chrome, tab: entry.tab, pane: pane, entersWindowFullScreen: entersFullScreen)
        services.hoverCards.dismiss(.action)
        pane.presentsPage = true
        root.presentsPage = true
        // While leaving, AppKit ignores a toggle: `windowDidExitFullScreen` enters again.
        if entersFullScreen, !leaving, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
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
        guard presentation.entersWindowFullScreen, let window else { return }
        // AppKit ignores a toggle mid-transition: an exit during the enter waits for its end.
        if isEnteringFullScreen {
            pageFullScreenExitPending = true
        } else if window.styleMask.contains(.fullScreen), (window as? ShellWindow)?.isLeavingFullScreen != true {
            window.toggleFullScreen(nil)
        }
    }

    /// The enter transition ended: an exit that waited for it runs now.
    private func pageFullScreenEnterDidEnd() {
        isEnteringFullScreen = false
        guard pageFullScreenExitPending else { return }
        pageFullScreenExitPending = false
        if pagePresentation == nil, let window, window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
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

    /// After a tab switch, a workspace switch or a pane resize: a page no longer on screen leaves
    /// fullscreen (Chrome does on a tab switch); one with a workspace now shown beside it stays
    /// fullscreen in its pane, and the window's chrome comes back.
    func revalidatePagePresentation() {
        guard let presentation = pagePresentation else { return }
        // On screen: still in its pane, which is still a shown pane of the shown workspace (a top
        // page parks the workspace before it hides it).
        guard let chrome = presentation.chrome, let pane = presentation.pane as? PaneController, let content,
              chrome.window === window, !chrome.isHiddenOrHasHiddenAncestor, chrome.isDescendant(of: pane.view), chrome.tab === presentation.tab,
              pane.isVisible, content.panes.values.contains(where: { $0 === pane }) else {
            let tab = presentation.tab
            endPagePresentation()
            tab?.exitContentFullscreen()
            return
        }
        if shownPane(showing: chrome) === pane { return }
        endPagePresentation()
    }

    /// The shown pane with `chrome`, when no workspace shows beside this one (panes beside it hide).
    private func shownPane(showing chrome: BrowserChromeView) -> PaneController? {
        guard let content, !parked.values.contains(where: { !$0.drawsNothing }), !chrome.isHiddenOrHasHiddenAncestor else { return nil }
        return content.panes.values.first { $0.isVisible && chrome.isDescendant(of: $0.view) }
    }
}
