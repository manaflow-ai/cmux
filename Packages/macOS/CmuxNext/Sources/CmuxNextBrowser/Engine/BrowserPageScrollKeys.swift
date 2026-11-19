import AppKit

/// The keys held down in cmux, for a held `j` or `k` in a page (``BrowserPageScroll``). The page
/// ends the scroll on its own key-up; this ends it on the key-ups the page cannot see (the key
/// went up before the start script ran, or in another window). A scroll whose key is not down
/// (the palette, a tap already over) runs as one step.
public final class BrowserPageScrollKeys {
    /// Held key codes: their letters (lowercased, modifiers ignored) and when their last key-down
    /// or repeat arrived, on the process's uptime clock. Not `NSEvent.timestamp`: that clock
    /// counts time asleep, so on a Mac that slept it was hours ahead of `systemUptime` and every
    /// held key looked stale (cmux-lawrence-2, 2026-11-17).
    private var down: [UInt16: (letter: String, at: TimeInterval)] = [:]
    /// A key-up another app took leaves its key here; a key with no key-down or repeat for
    /// longer than the slowest initial key-repeat delay (1.8 s) is not held.
    static let stale: TimeInterval = 2.5
    /// The scroll a held key runs.
    private var running: (tab: WeakTab, scroll: BrowserPageScroll)?
    private var monitor: Any?

    /// Watches the app's key events from the start (the first hold must see its key-down); it
    /// never consumes one.
    public init(watching: Bool = true) {
        guard watching else { return }
        // AppKit calls a local monitor on the main thread (the module's isolation), like `MouseSideButtons`.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    private final class WeakTab {
        weak var tab: (any BrowserTab)?
        init(_ tab: any BrowserTab) { self.tab = tab }
    }

    func observe(_ event: NSEvent, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if event.type == .keyDown {
            guard let letter = event.charactersIgnoringModifiers?.lowercased(), !letter.isEmpty else { return }
            down[event.keyCode] = (letter, now)
        } else if event.type == .keyUp, let key = down.removeValue(forKey: event.keyCode),
                  let running, running.scroll.letter == key.letter {
            self.running = nil
            running.tab.tab?.releaseScroll(running.scroll)
        }
    }

    /// Runs `scroll` on `tab`: `j` and `k` scroll while their key is down, else one step.
    public func run(_ scroll: BrowserPageScroll, on tab: any BrowserTab) {
        guard let letter = scroll.letter else { return tab.scroll(scroll) }
        let now = ProcessInfo.processInfo.systemUptime
        guard down.values.contains(where: { $0.letter == letter && now - $0.at < Self.stale }) else { return tab.scroll(scroll, releasing: true) }
        if let running, running.tab.tab !== tab { running.tab.tab?.releaseScroll(running.scroll) }
        running = (WeakTab(tab), scroll)
        tab.scroll(scroll, topSpeed: BrowserPageScroll.topSpeed(keyRepeatInterval: NSEvent.keyRepeatInterval))
    }
}
