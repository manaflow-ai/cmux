import AppKit
import CmuxNextDesign

// Chrome commands (key equivalents the chrome handles itself), the toolbar page's commands (each
// runs the handler its native control ran), and the row's hiding.
extension BrowserChromeView {
    /// The find pill on the current tab, made on first use (#32909); `shownFindBar` while it shows.
    var findBar: FindBarView { pageBars.findBar(on: tab) }
    var shownFindBar: FindBarView? { pageBars.findBarIfMade.flatMap { $0.isHidden ? nil : $0 } }

    public func perform(_ command: BrowserChromeCommand) {
        switch command {
        case .focusAddressBar: addressBar.focus()
        case .findInPage: showFindBar()
        case .findNext: if let shown = shownFindBar { shown.findNext() } else { showFindBar() }
        case .findPrevious: if let shown = shownFindBar { shown.findPrevious() } else { showFindBar() }
        case .reload: tab.reload()
        case .stop: tab.stop()
        case .goBack: tab.goBack()
        case .goForward: tab.goForward()
        case .zoomIn: tab.zoomIn(); siteZoom.userDidZoom()
        case .zoomOut: tab.zoomOut(); siteZoom.userDidZoom()
        case .resetZoom: tab.resetZoom(); siteZoom.userDidZoom()
        case .showDevTools: tab.showDevTools()
        }
    }

    /// A press on the toolbar page: the same tab call, registry action or menu its native button ran.
    func performToolbarCommand(_ command: BrowserToolbarPageCommand) {
        switch command {
        case .goBack: tab.goBack()
        case .goForward: tab.goForward()
        case .reload: tab.reload()
        case .stop: tab.stop()
        case .navigationMenu(let button): showNavigationMenu(button)
        case .toolbarButton(let button): toolbarButtons.press(button)
        case .extensionAction(let id): extensionActions.run(id)
        case .extensionContextMenu(let id): extensionActions.showItemMenu(id)
        case .extensionsMenu: extensionActions.showMenu()
        case .reloadCrashedExtensions: extensionActions.reloadCrashed()
        case .moveExtension(let id, let index): extensionActions.movePinned(id, to: index)
        default: break
        }
    }

    /// The page laid the row out: the trailing buttons' collapse and the pinned actions it had room
    /// for follow (More and the Extensions bubble list the rest).
    func toolbarDidLayOut(_ report: BrowserToolbarLayoutReport) {
        toolbarButtons.setCollapse(report.collapse)
        extensionActions.visibleLimit = report.visiblePinned
    }

    /// The trailing buttons changed (a tab's state, a download, a pin, a menu opened under one).
    func pushButtons() { addressBar.buttonsWire = toolbarButtons.wire }

    /// The bound tab's extension actions changed.
    func pushExtensions() { addressBar.extensionsWire = extensionActions.wire }

    // MARK: Hiding the row

    /// Toggle Omnibar (`palette.browserToggleOmnibar`): hides the address bar row of this tab, or
    /// shows it again. Pane fullscreen still hides it.
    public func toggleOmnibar() {
        isOmnibarHidden.toggle()
        setToolbarHidden(isOmnibarHidden || tab.state.isContentFullscreen)
    }

    /// The row hides while the page is in pane fullscreen, or while the person hid it.
    func setToolbarHidden(_ hidden: Bool) {
        guard hidden != isToolbarHidden else { return }
        isToolbarHidden = hidden
        let height = hidden ? 0 : currentToolbarHeight
        if !hidden { toolbar.isHidden = false; separator.isHidden = false }
        accessoryBar.isHidden = hidden
        applyAccessoryHeight()
        Motion.overlays.animateTimed(hidden ? .disappear : .appear, in: self, {
            // Outside a window no display runs the animation, so set the constant directly.
            (self.window == nil ? self.toolbarHeight : Motion.animator(self.toolbarHeight, in: self)).constant = height
            self.layoutSubtreeIfNeeded()
        }, completion: {
            if self.isToolbarHidden {
                self.toolbar.isHidden = true
                self.separator.isHidden = true
            }
        })
    }
}
