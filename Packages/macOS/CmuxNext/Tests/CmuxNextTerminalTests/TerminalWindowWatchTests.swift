import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// The terminals' window notices go through the window's one ``WindowEvents`` (recipe
/// R-notif): a Cmd-Tab with many terminals handles the key change only in the first responder, in its own turn
/// even when its window is covered, a hidden tab reads a screen change once when it shows, and an occlusion
/// change still reaches every shown terminal, so a covered window stops drawing whatever its tabs show. The
/// host's appearance repaint waits for its tab the same way (recipe R-appear).
@MainActor @Suite struct TerminalWindowWatchTests {
    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// One terminal's watch with its own change log.
    @MainActor private final class Terminal {
        let watch: TerminalWindowWatch
        var changes: [TerminalWindowWatch.Change] = []

        init(node: VisibilityNode?) {
            watch = TerminalWindowWatch(node: node)
            watch.onChange = { [unowned self] change in self.changes.append(change) }
        }
    }

    /// Cmd-Tab back to a window with 40 shown terminals, 4 of them in visible tabs and one first responder:
    /// one NotificationCenter observer for the key notice, and the key change is handled once, not 40 times.
    @Test func cmdTabWithFortyTerminalsHandlesOnlyTheFirstResponder() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let windowNode = VisibilityNode(root: "window", own: .visible)
        let terminals = (0..<40).map { index in
            Terminal(node: VisibilityNode("tab:\(index)", own: index < 4 ? .visible : .hidden, parent: windowNode))
        }
        for terminal in terminals { terminal.watch.watch(events) }
        terminals[0].watch.followKey(true)
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 1)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(events.deliveries(NSWindow.didBecomeKeyNotification) == 1, "one observer for every terminal")
        let handled = terminals.reduce(0) { $0 + $1.changes.count }
        #expect(handled <= 4, "a Cmd-Tab handled \(handled) key changes for 4 visible terminals")
        #expect(terminals[0].changes == [.focus])
        #expect(terminals.dropFirst().allSatisfy { $0.changes.isEmpty },
                "a terminal that is not first responder handled the key change")
    }

    /// The first-responder terminal of a window an opaque window covers hears a resign and a become key in
    /// their own turns: its focus report and `isFocused` do not wait for the window to be uncovered.
    @Test func theFirstResponderHearsKeyChangesWhileItsWindowIsOccluded() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let windowNode = VisibilityNode(root: "window", own: .occluded)
        let pane = VisibilityNode("pane", own: .visible, parent: windowNode)
        let tab = VisibilityNode("tab", own: .visible, parent: pane)
        #expect(!tab.isVisible)
        let terminal = Terminal(node: tab)
        terminal.watch.watch(events)
        terminal.watch.followKey(true)
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(terminal.changes == [.focus], "the resign key waited for the window to show")
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(terminal.changes == [.focus, .focus], "the become key waited for the window to show")
        windowNode.set(.visible)
        #expect(terminal.changes == [.focus, .focus], "showing the window replayed a key change")
    }

    /// Key changes follow first responder: following before the watch applies on watch, resigning ends them,
    /// and a stop keeps the state for the next watch.
    @Test func keyChangesFollowFirstResponder() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let terminal = Terminal(node: VisibilityNode(root: "tab", own: .visible))
        terminal.watch.followKey(true)
        terminal.watch.watch(events)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(terminal.changes == [.focus])
        terminal.watch.followKey(false)
        #expect(!events.isObserving(NSWindow.didBecomeKeyNotification))
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(terminal.changes == [.focus], "a resigned terminal handled a key change")
        terminal.watch.followKey(true)
        terminal.watch.stop()
        terminal.watch.watch(events)
        center.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(terminal.changes == [.focus, .focus])
    }

    /// A hidden tab's terminal gets no call per screen post and reads the window's screen once when its tab shows.
    @Test func aHiddenTabReadsTheScreenChangeOnceWhenItShows() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let tab = VisibilityNode(root: "tab", own: .hidden)
        let terminal = Terminal(node: tab)
        terminal.watch.watch(events)
        for _ in 0..<3 {
            center.post(name: NSWindow.didResignKeyNotification, object: window)
            center.post(name: NSWindow.didBecomeKeyNotification, object: window)
            center.post(name: NSWindow.didChangeScreenNotification, object: window)
        }
        #expect(terminal.changes.isEmpty, "a hidden terminal handled a key or screen change")
        tab.set(.visible)
        #expect(terminal.changes == [.screen],
                "showing the tab replayed every post, or a key change reached a terminal that is not first responder")
    }

    /// An occlusion change reaches a shown terminal whose tab is not visible: its surface still pauses
    /// drawing while the window is covered (the side effect runs while hidden).
    @Test func occlusionReachesAHiddenTabsTerminal() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let terminal = Terminal(node: VisibilityNode(root: "tab", own: .hidden))
        terminal.watch.watch(events)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(terminal.changes == [.occlusion])
    }

    /// A first-responder terminal with no tab (tests, fixtures) follows its window's notices whenever it is shown.
    @Test func aTerminalWithNoTabFollowsEveryNotice() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let terminal = Terminal(node: nil)
        terminal.watch.watch(events)
        terminal.watch.followKey(true)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        #expect(terminal.changes == [.focus, .screen])
    }

    /// Stopping (the terminal hidden, parked or out of its window) ends every subscription and its pending
    /// missed call, and the window's last observer goes with them.
    @Test func stopEndsTheSubscriptionsAndTheMissedCall() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let tab = VisibilityNode(root: "tab", own: .hidden)
        let terminal = Terminal(node: tab)
        terminal.watch.watch(events)
        terminal.watch.followKey(true)
        center.post(name: NSWindow.didChangeScreenNotification, object: window)
        terminal.watch.stop()
        #expect(!terminal.watch.isWatching)
        #expect(!events.isObserving(NSWindow.didBecomeKeyNotification))
        #expect(!events.isObserving(NSWindow.didChangeScreenNotification))
        tab.set(.visible)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(terminal.changes.isEmpty)
    }

    /// A light/dark switch repaints a hidden terminal's host once, when its tab shows, not in the switch's turn.
    @Test func aHiddenHostRepaintsItsAppearanceOnShow() {
        _ = NSApplication.shared
        let tab = VisibilityNode(root: "tab", own: .hidden)
        let host = TerminalHostView(mainWork: MainWorkScheduler(budget: MainFrameBudget()), node: tab)
        host.viewDidChangeEffectiveAppearance()
        host.viewDidChangeEffectiveAppearance()
        #expect(tab.deferredCount == 1, "a hidden host repainted in the switch's turn, or queued one repaint per switch")
        tab.set(.visible)
        #expect(tab.deferredCount == 0)
        host.viewDidChangeEffectiveAppearance()
        #expect(tab.deferredCount == 0, "a visible host deferred its repaint")
    }
}
