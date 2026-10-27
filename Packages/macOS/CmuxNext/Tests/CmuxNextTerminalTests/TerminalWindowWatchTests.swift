import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Testing

/// The terminals' window notices go through the window's one ``WindowEvents`` by their tab nodes
/// (p06-scheduler-334, recipe R-notif): a Cmd-Tab with many terminals handles the key change only in the
/// visible ones, a hidden tab reads it once when it shows, and an occlusion change still reaches every shown
/// terminal, so a covered window stops drawing whatever its tabs show. The host's appearance repaint waits
/// for its tab the same way (recipe R-appear).
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

    /// Cmd-Tab back to a window with 40 shown terminals, 4 of them in visible tabs: one NotificationCenter
    /// observer per notice for all 40, and the key change is handled 4 times, not 40.
    @Test func cmdTabWithFortyTerminalsHandlesOnlyTheVisibleOnes() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let windowNode = VisibilityNode(root: "window", own: .visible)
        let terminals = (0..<40).map { index in
            Terminal(node: VisibilityNode("tab:\(index)", own: index < 4 ? .visible : .hidden, parent: windowNode))
        }
        for terminal in terminals { terminal.watch.watch(events) }
        #expect(events.subscriberCount(NSWindow.didBecomeKeyNotification) == 40)
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(events.deliveries(NSWindow.didBecomeKeyNotification) == 1, "one observer for every terminal")
        let handled = terminals.reduce(0) { $0 + $1.changes.count }
        #expect(handled <= 4, "a Cmd-Tab handled \(handled) key changes for 4 visible terminals")
        #expect(terminals.prefix(4).allSatisfy { $0.changes == [.focus] })
        #expect(terminals.dropFirst(4).allSatisfy { $0.changes.isEmpty }, "a hidden tab handled the key change")
    }

    /// A hidden tab's terminal gets no call per post and reads the window's state once when its tab shows.
    @Test func aHiddenTabReadsTheKeyChangeOnceWhenItShows() {
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
        let focusReads = terminal.changes.filter { $0 == .focus }.count
        let screenReads = terminal.changes.filter { $0 == .screen }.count
        #expect(focusReads >= 1)
        #expect(screenReads == 1, "the screen change was read more than once on show")
        #expect(terminal.changes.count <= 3, "showing the tab replayed every post")
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

    /// A terminal with no tab (tests, fixtures) follows its window's notices whenever it is shown.
    @Test func aTerminalWithNoTabFollowsEveryNotice() {
        let center = NotificationCenter(), window = Self.window()
        let events = WindowEvents(window: window, center: center)
        let terminal = Terminal(node: nil)
        terminal.watch.watch(events)
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
        center.post(name: NSWindow.didBecomeKeyNotification, object: window)
        terminal.watch.stop()
        #expect(!terminal.watch.isWatching)
        #expect(!events.isObserving(NSWindow.didBecomeKeyNotification))
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
