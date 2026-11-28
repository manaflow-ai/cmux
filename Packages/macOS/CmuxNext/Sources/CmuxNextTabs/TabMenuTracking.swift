import AppKit

// MARK: - Menus keep the trailing buttons

/// A menu from the strip keeps its trailing buttons while it is open, since the pointer leaves the
/// strip for it. The strip holds one and calls `begin` before a menu shows and `end` after.
@MainActor final class TabMenuTracking {
    private weak var strip: TabStripView?
    /// End-of-tracking observer of the menu the strip returned last.
    private var endObserver: (any NSObjectProtocol)?

    init(strip: TabStripView) { self.strip = strip }

    /// A menu from this strip is about to show: the trailing buttons stay
    /// while it is open, since the pointer leaves the strip for it.
    func begin(_ menu: NSMenu) {
        end()
        strip?.buttonReveal.menuOpen = true
        endObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() } // main-proof: observer on queue: .main
        }
    }

    /// The menu closed. AppKit sends no exit event for a pointer that left
    /// during menu tracking, so the pointer is checked here.
    func end() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        guard let strip, strip.buttonReveal.menuOpen else { return }
        strip.buttonReveal.menuOpen = false
        if let window = strip.window, !strip.bounds.contains(strip.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            strip.buttonReveal.pointerInStrip = false
        }
    }
}
