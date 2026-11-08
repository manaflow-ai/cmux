public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import CmuxNextIcons

// Extensions toolbar and menu, the toolbar report, and the chrome's window and size changes.
extension BrowserChromeView {
    /// Accessibility identifiers of the toolbar (UI automation, e2e suites).
    public static let backIdentifier = "browser.toolbar.back"
    public static let forwardIdentifier = "browser.toolbar.forward"
    public static let reloadIdentifier = "browser.toolbar.reload"
    public static let omnibarIdentifier = "browser.toolbar.omnibar"
    public static let pageGoneIdentifier = "browser.page.gone"
    public static let pageGoneReloadIdentifier = "browser.page.gone.reload"
    public static let pageUnresponsiveIdentifier = "browser.page.unresponsive"
    public static let pageUnresponsiveWaitIdentifier = "browser.page.unresponsive.wait"
    public static let pageUnresponsiveExitIdentifier = "browser.page.unresponsive.exit"

    /// Runs the Extensions menu's items (the App's action registry). Nil
    /// drives the extension store directly.
    public var extensionMenuHandler: (any ExtensionMenuHandling)? {
        get { extensionActions.menuHandler }
        set { extensionActions.menuHandler = newValue }
    }

    /// Opens the Extensions (puzzle) bubble of a Chromium tab; an open bubble stays open.
    public func showExtensionsMenu() { extensionActions.openMenu() }

    /// Shows one extension's menu at its toolbar button (or the Extensions
    /// button when it is not shown).
    public func showExtensionItemMenu(_ id: String) { extensionActions.showItemMenu(id) }

    /// Opens the Extensions menu (or `id`'s menu) on the next run-loop turn, for callers that must return first
    /// (CLI, palette, debug socket): its tracking loop runs in a run-loop callout, so main-actor work keeps running.
    /// The tab has the extension toolbar but the Extensions button is not shown, so More offers the Extensions
    /// menu (cx-d0d.81). The button now shows on every Chromium tab, so this holds only while it is unbound.
    public var offersExtensionsMenuInMore: Bool {
        extensionActions.host != nil && !extensionActions.isShowingExtensions
    }

    public func presentExtensionsMenu(for id: String? = nil) {
        MainRunLoopBlock.perform { [weak self] in
            guard let self else { return }
            if let id { self.showExtensionItemMenu(id) } else { self.showExtensionsMenu() }
        }
    }

    /// Runs an extension's toolbar action anchored to its button (or the
    /// Extensions button when it is not pinned or has no room).
    public func runExtensionAction(_ id: String) { extensionActions.run(id) }

    /// Moves a pinned extension to `index` among the pinned ones (the
    /// toolbar drag). False when the runtime cannot reorder (fork API < 6).
    @discardableResult
    public func moveExtensionAction(_ id: String, to index: Int) -> Bool { extensionActions.movePinned(id, to: index) }

    /// Whether the Extensions bubble, or an extension's menu at its toolbar icon, is open.
    public var isExtensionsMenuShown: Bool { extensionActions.isMenuShown || extensionActions.presentedMenu != nil }

    /// What the open Extensions bubble or extension menu shows (`debug.extensions.menu`): each
    /// item's title, identifier, extension id and enabled state; "-" titles are separators. Nil
    /// when nothing is open.
    public var extensionsMenuItems: [(title: String, identifier: String?, extensionID: String?, enabled: Bool)]? {
        if let menu = extensionActions.presentedMenu {
            return menu.items.map { item in
                (item.isSeparatorItem ? "-" : item.title, item.identifier?.rawValue, nil, item.isEnabled)
            }
        }
        return extensionActions.menuController.report?.map { ($0.title, $0.identifier, $0.extensionID, $0.isEnabled) }
    }

    /// Chooses an item of the open Extensions bubble or extension menu as a click would: a row control (`run`, `pin`,
    /// `unpin`, `more`) of `extensionID`, `manage`, `close`, or an extension menu operation (`options`, `remove`,
    /// `siteAccess`, `homePage`, `manageExtension`, `webPermissions`, `pin`, `unpin`). False when no item matches.
    public func chooseInExtensionsMenu(_ operation: String, extension extensionID: String?) -> Bool {
        if let menu = extensionActions.presentedMenu, let extensionID,
           let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "\(ExtensionsMenu.moreIdentifier(extensionID)).\(operation)" }) {
            menu.cancelTracking()
            menu.performActionForItem(at: index)
            return true
        }
        return extensionActions.menuController.choose(operation, extension: extensionID)
    }

    /// Closes the open extension menu, else the Extensions bubble.
    public func dismissExtensionsMenu() {
        if let menu = extensionActions.presentedMenu { menu.cancelTracking() } else { extensionActions.menuControllerIfMade?.dismiss() }
    }

    /// What the toolbar shows now (`debug.extensions.toolbar`): the controls the page laid out, in
    /// this view's coordinates.
    public var toolbarReport: BrowserToolbarReport {
        let layout = addressBar.layoutReport
        var frames: [String: CGRect] = [:]
        for key in layout.rects.keys {
            guard let anchor = addressBar.anchor(key), anchor.window != nil else { continue }
            frames[key] = anchor.convert(anchor.bounds, to: self)
        }
        var icons: [String: IconName] = [:]
        for button in BrowserToolbarButton.allCases where frames["button:\(button.rawValue)"] != nil {
            if let icon = toolbarButtons.state(button)?.icon { icons["button:\(button.rawValue)"] = icon }
        }
        let host = extensionActions.host
        return BrowserToolbarReport(
            width: bounds.width, showsForward: layout.showsForward,
            showsExtensionsButton: extensionActions.isShowingExtensions,
            visibleActions: extensionActions.visibleIDs, overflowActions: extensionActions.overflowIDs,
            openPopup: host?.openExtensionPopup,
            popupAnchor: host?.openExtensionPopup.flatMap { extensionActions.anchorRect(for: $0) }
                .map { tab.contentView.convert($0, to: self) },
            frames: frames, icons: icons, toolbarBounds: toolbar.convert(toolbar.bounds, to: self)
        )
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width, grew = frame.size == .zero && newSize != .zero
        super.setFrameSize(newSize)
        // A relaunch's restored tab: its chrome made at zero and sized in the pass that shows it drew its toolbar empty
        // for a frame (address bar and buttons at 0x0), then filled in. Its constraints are solved now, in that pass.
        if grew, window != nil { layoutSubtreeIfNeeded() }
        guard widthChanged else { return }
        // A popup hangs off a toolbar button that moves or collapses now.
        extensionActions.hidePopups()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            extensionActions.hidePopups()
            toolbarButtons.detached()
        }
        // A tab shown again repaints: overrides may have changed while it was out (R55).
        else {
            updateColors()
            renderPrompt()
            toolbarButtons.refresh()
            if frame.size != .zero, toolbar.frame.size == .zero { layoutSubtreeIfNeeded() } // sized before it had a window
        }
        headerBandReattachIfInstalled()
        syncPageOverlays()
    }

    /// Its pane parked this tab hidden (another tab shows): popups close, as
    /// when it leaves the window.
    public override func viewDidHide() {
        super.viewDidHide()
        extensionActions.hidePopups()
        toolbarButtons.detached()
        syncPageOverlays()
    }

    /// Its pane shows this parked tab again: it repaints, as when it comes
    /// back into the window (R55). The pane re-pins its header band itself.
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        // Shown during its pane's key hold (a tab switch): it follows the pane from this frame (FRAME OWNER S3).
        (superview as? PaneContentAreaView)?.followerDidShow()
        guard window != nil else { return }
        updateColors()
        renderPrompt()
        toolbarButtons.refresh()
        syncPageOverlays()
    }

    /// The region of this chrome that contains `view`, nil when outside.
    public func region(of view: NSView) -> Region? {
        guard view.isDescendant(of: self) else { return nil }
        if view.isDescendant(of: addressBar) { return .addressBar }
        if let findBar = pageBars.findBarIfMade, view.isDescendant(of: findBar) { return .findBar }
        if view.isDescendant(of: tab.contentView) { return .page }
        return .chrome
    }
}

/// The browser toolbar as laid out now, in chrome view coordinates.
public struct BrowserToolbarReport: Equatable, Sendable {
    public var width: CGFloat
    public var showsForward: Bool
    public var showsExtensionsButton: Bool
    /// Pinned actions shown as buttons, in order.
    public var visibleActions: [String]
    /// Pinned actions in the Extensions menu for lack of room.
    public var overflowActions: [String]
    public var openPopup: String?
    /// Where the open popup is anchored (its button, or the Extensions button).
    public var popupAnchor: CGRect?
    /// Visible controls: "back", "forward", "reload", "omnibar",
    /// "extensions", "action:<id>".
    public var frames: [String: CGRect]
    /// The pack icon each visible icon button draws, keyed like `frames`.
    public var icons: [String: IconName]
    public var toolbarBounds: CGRect

    /// Every control lies inside the toolbar and no two overlap.
    public var fits: Bool {
        let rects = Array(frames.values)
        for (index, rect) in rects.enumerated() {
            guard rect.width > 0, toolbarBounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) else { return false }
            for other in rects[(index + 1)...] where rect.insetBy(dx: 0.5, dy: 0.5).intersects(other) { return false }
        }
        return true
    }
}

extension BrowserChromeView {
    /// The tab was restored showing `url` (relaunch, hibernation wake): its
    /// first load of that page is not recorded as a new visit.
    public func markRestored(_ url: URL?) { loads.markRestored(url) }
}
