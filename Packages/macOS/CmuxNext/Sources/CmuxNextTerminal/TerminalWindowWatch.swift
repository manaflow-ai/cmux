import AppKit
import CmuxNextWakeups

/// The window notices a shown terminal handles, through its window's one ``WindowEvents``: one NotificationCenter
/// observer per window and notice, not four per terminal, as Chromium observes an NSWindow once per widget
/// (components/remote_cocoa/app_shim/views_nswindow_delegate.mm). A terminal that is not shown watches nothing
/// (`TerminalSurfaceView.observeWindow`). Key changes reach only the first-responder terminal (at most one per
/// window), in their own turn whatever its node shows: its focus is a model write and the program's focus report,
/// as Chromium's windowDidBecomeKey/windowDidResignKey reach NativeWidgetNSWindowBridge::OnWindowKeyStatusChangedTo
/// whatever the occlusion. Any other terminal's focus is false whatever the key window. Screen changes reach a shown
/// terminal only while its node (its tab's) is visible; one that missed some reads the window's state once when the
/// node shows. Occlusion is not a notice here: the terminal follows its window's node (`TerminalSurfaceView.watchWindowNode`),
/// which AppKit's occlusion notice and the window's occlusion family both feed.
@MainActor
final class TerminalWindowWatch {
    /// What a window notice changes for the surface.
    enum Change {
        /// Whether its window is key: Ghostty's focus.
        case focus
        /// Its screen: scale, display and size.
        case screen
    }

    /// The node screen notices follow: the tab's, else an always-visible root of its own (no tab: tests, fixtures).
    let node: VisibilityNode
    /// Where each change goes: the surface's `windowStateChanged` (it sets this after its own init).
    var onChange: @MainActor (Change) -> Void = { _ in }
    private var subscriptions: [EventSubscription] = []
    private var keySubscriptions: [EventSubscription] = []
    /// The followed window's events (its window keeps them).
    private weak var events: WindowEvents?
    /// Whether the terminal is its window's first responder, so key changes reach it (``followKey(_:)``).
    private(set) var followsKey = false

    /// - Parameter node: The terminal's tab node; nil follows the window's notices whenever the terminal is shown.
    init(node: VisibilityNode?) {
        self.node = node ?? VisibilityNode(root: "terminal.untabbed", own: .visible)
    }

    /// Whether it follows a window now.
    var isWatching: Bool { !subscriptions.isEmpty }

    /// Follows a window's notices through its `events` (`WindowEvents.of(window)`), replacing any it followed.
    func watch(_ events: WindowEvents) {
        stop()
        self.events = events
        let owner = "TerminalSurfaceView"
        subscriptions = [
            events.subscribe(NSWindow.didChangeScreenNotification, node: node, delivery: .whenVisible, owner: owner) { [weak self] _ in
                self?.onChange(.screen)
            },
        ]
        subscribeKey()
    }

    /// Follows key changes while `follow` (the terminal became first responder) and drops them when it resigns.
    /// Kept across ``stop()``: the next ``watch(_:)`` follows them again while the terminal is first responder.
    func followKey(_ follow: Bool) {
        guard follow != followsKey else { return }
        followsKey = follow
        subscribeKey()
    }

    /// Ends every subscription, a pending missed call included.
    func stop() {
        for subscription in subscriptions + keySubscriptions { subscription.cancel() }
        subscriptions.removeAll()
        keySubscriptions.removeAll()
        events = nil
    }

    private func subscribeKey() {
        for subscription in keySubscriptions { subscription.cancel() }
        keySubscriptions.removeAll()
        guard followsKey, let events else { return }
        let owner = "TerminalSurfaceView"
        keySubscriptions = [
            events.subscribe(NSWindow.didBecomeKeyNotification, node: node, delivery: .always, owner: owner) { [weak self] _ in
                self?.onChange(.focus)
            },
            events.subscribe(NSWindow.didResignKeyNotification, node: node, delivery: .always, owner: owner) { [weak self] _ in
                self?.onChange(.focus)
            },
        ]
    }
}
