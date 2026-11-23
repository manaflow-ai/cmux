public import AppKit
import CmuxNextCompat
public import CmuxNextDesign

extension BrowserToolbarButtonsView {
    /// Opens `menu` on cmux's glass (``GlassMenu``) under `button` (under More when the button is
    /// collapsed), trailing edges lined up, on the next run-loop turn so a CLI or palette caller
    /// returns first: the browser More menu. A second press while it is open closes it.
    ///
    /// The button draws pressed while the menu is open. When the menu closes, the window's first
    /// responder is the one it had at the open (the page), before a picked row runs and moves it on
    /// (Find in Page to its field).
    public func presentGlass(_ menu: NSMenu, from button: BrowserToolbarButton) {
        refresh()
        MainRunLoopBlock.perform { [weak self] in self?.openGlass(menu, from: button) }
    }

    /// The More menu's zoom row from `parts`, Zoom Out, Zoom In and Actual Size: Zoom, then −, this
    /// toolbar's page zoom, + and reset, which run their items with the menu open. Nil unless there
    /// are three.
    public func zoomRow(_ parts: [NSMenuItem]) -> NSMenuItem? {
        guard parts.count == 3 else { return nil }
        let row = GlassMenuStepperItem(title: BrowserToolbarButton.zoomRowTitle, decrement: parts[0], increment: parts[1],
                                       reset: parts[2]) { [weak self] in "\(BrowserZoom.percent(self?.tab?.state.zoom ?? 1))%" }
        row.image = NSImage.menuSymbol("magnifyingglass")
        row.identifier = NSUserInterfaceItemIdentifier("cmux.browser.more.zoom")
        return row
    }

    /// The glass More menu while it is open (``presentGlass(_:from:)``), else nil.
    public var shownGlassMenu: GlassMenu? { openGlassMenu?.isShown == true ? openGlassMenu : nil }

    /// ``presentGlass(_:from:)``'s open, at once (tests).
    func openGlass(_ menu: NSMenu, from button: BrowserToolbarButton) {
        if let open = openGlassMenu, open.isShown {
            open.close()
            return
        }
        guard let anchor = anchor(for: button), let window = anchor.window else { return }
        let glass = GlassMenu(menu: menu)
        let pressed = anchor as? ChromeIconButton
        weak var focused = window.firstResponder
        glass.onClose = { [weak self, weak window, weak glass] in
            pressed?.isMenuOpen = false
            pressed?.pressTracker = nil
            if let self, self.openGlassMenu === glass { self.openGlassMenu = nil }
            guard let window, let focused, window.firstResponder !== focused else { return }
            if let view = focused as? NSView, view.window !== window { return }
            FocusRoute(.person, "the More menu closed: back to the page it opened over").moveKeyboard(in: window, to: focused)
        }
        guard showGlassMenu(glass, anchor) else { return }
        pressed?.isMenuOpen = true
        // Opened by a press still held: its drag and its release pick a row, as on an NSMenu.
        if let pressed, pressed.holdsPress { pressed.pressTracker = { [weak glass] in glass?.trackPress($0) } }
        openGlassMenu = glass
    }
}
