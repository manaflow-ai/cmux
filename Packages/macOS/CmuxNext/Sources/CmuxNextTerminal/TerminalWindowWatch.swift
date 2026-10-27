import AppKit
import CmuxNextWakeups

/// The window notices a shown terminal handles, through its window's one ``WindowEvents``: one NotificationCenter
/// observer per window and notice, not four per terminal, as Chromium observes an NSWindow once per widget
/// (components/remote_cocoa/app_shim/views_nswindow_delegate.mm). A terminal that is not shown watches nothing
/// (`TerminalSurfaceView.observeWindow`). Key and screen changes reach a shown terminal only while its node (its
/// tab's) is visible; one that missed some reads the window's state once when the node shows. Every shown terminal
/// hears an occlusion change, visible or not: its drawing pauses while the window is covered.
@MainActor
final class TerminalWindowWatch {
    /// What a window notice changes for the surface.
    enum Change {
        /// Whether it draws.
        case occlusion
        /// Whether its window is key: Ghostty's focus.
        case focus
        /// Its screen: scale, display and size.
        case screen
    }

    /// The node key and screen notices follow: the tab's, else an always-visible root of its own (no tab: tests, fixtures).
    let node: VisibilityNode
    /// Where each change goes: the surface's `windowStateChanged` (it sets this after its own init).
    var onChange: @MainActor (Change) -> Void = { _ in }
    private var subscriptions: [EventSubscription] = []

    /// - Parameter node: The terminal's tab node; nil follows the window's notices whenever the terminal is shown.
    init(node: VisibilityNode?) {
        self.node = node ?? VisibilityNode(root: "terminal.untabbed", own: .visible)
    }

    /// Whether it follows a window now.
    var isWatching: Bool { !subscriptions.isEmpty }

    /// Follows a window's notices through its `events` (`WindowEvents.of(window)`), replacing any it followed.
    func watch(_ events: WindowEvents) {
        stop()
        let owner = "TerminalSurfaceView"
        subscriptions = [
            events.subscribe(NSWindow.didChangeOcclusionStateNotification, node: node, delivery: .always, owner: owner) { [weak self] _ in
                self?.onChange(.occlusion)
            },
            events.subscribe(NSWindow.didBecomeKeyNotification, node: node, delivery: .whenVisible, owner: owner) { [weak self] _ in
                self?.onChange(.focus)
            },
            events.subscribe(NSWindow.didResignKeyNotification, node: node, delivery: .whenVisible, owner: owner) { [weak self] _ in
                self?.onChange(.focus)
            },
            events.subscribe(NSWindow.didChangeScreenNotification, node: node, delivery: .whenVisible, owner: owner) { [weak self] _ in
                self?.onChange(.screen)
            },
        ]
    }

    /// Ends every subscription, a pending missed call included.
    func stop() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
    }
}
