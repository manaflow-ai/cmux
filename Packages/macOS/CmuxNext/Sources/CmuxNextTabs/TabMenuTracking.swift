import AppKit
import CmuxNextCompat

// MARK: - Menus keep the trailing buttons

/// A menu from the strip keeps its trailing buttons while it is open, since the pointer leaves the
/// strip for it. The strip holds one and calls `begin` before a menu shows and `end` after.
@MainActor final class TabMenuTracking {
    private weak var strip: TabStripView?
    /// End-of-tracking observer of the menu the strip returned last (``MenuTracking``).
    private var endObserver: MenuTracking?

    init(strip: TabStripView) { self.strip = strip }

    /// A menu from this strip is about to show: the trailing buttons stay
    /// while it is open, since the pointer leaves the strip for it.
    func begin(_ menu: NSMenu, fromNewTabButton: Bool = false) {
        end()
        strip?.buttonReveal.menuOpen = true
        strip?.newTabButton.isMenuOpen = fromNewTabButton
        let menus = MenuTracking()
        menus.subscribe { [weak self, weak menu] change in
            if case .ended(let ended) = change, ended === menu { self?.end() }
        }
        endObserver = menus
    }

    /// The menu closed. AppKit sends no exit event for a pointer that left
    /// during menu tracking, so the pointer is checked here.
    func end() {
        endObserver = nil
        guard let strip, strip.buttonReveal.menuOpen else { return }
        strip.buttonReveal.menuOpen = false
        strip.newTabButton.isMenuOpen = false
        if let window = strip.window, !strip.bounds.contains(strip.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            strip.buttonReveal.pointerInStrip = false
        }
    }
}
