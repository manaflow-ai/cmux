public import AppKit
import CmuxNextCompat

/// The one rule for app panels that take the keyboard (the palette, the tab
/// group editor, the Page Info bubble).
///
/// These panels are nonactivating. A nonactivating panel that becomes key
/// takes the system keyboard even while its app is not active, so a panel
/// opened by a CLI request or in a `CMUX_NEXT_NO_ACTIVATE=1` run captured
/// what the user typed into their frontmost app. This panel takes the keys
/// only while the app is active: ``canBecomeKey`` says no otherwise, and
/// `makeKey`/`makeKeyAndOrderFront` only order it front. Shown without the
/// keys, it calls ``onKeyElsewhere`` once another window of the app becomes
/// key (a click or Cmd-Tab into the app), so the owner closes it the way a
/// click outside closes a key panel.
open class ActiveAppKeyPanel: NSPanel {
    /// Whether the app is active (tests inject their own per panel).
    public var isAppActive: () -> Bool = { NSApp?.isActive ?? false }

    /// Another window of the app took the keys while this panel was shown
    /// without them.
    public var onKeyElsewhere: (() -> Void)?
    /// The center that posts the app's key-window changes, fixed at init.
    public let keyWindowNotifications: NotificationCenter
    /// Watches for another window becoming key while shown without the keys; it stops
    /// observing when released (this panel's release included), so no deinit cleans it up.
    private var keyElsewhere: MainActorObservation?

    /// A panel that hears the app's key-window changes from `keyWindowNotifications`.
    ///
    /// - Parameter keyWindowNotifications: The center that posts `NSWindow.didBecomeKeyNotification`.
    ///   Tests pass their own, so a post there reaches only this panel.
    public init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType,
                defer flag: Bool, keyWindowNotifications: NotificationCenter) {
        self.keyWindowNotifications = keyWindowNotifications
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    /// A panel that hears the app's key-window changes from `NotificationCenter.default` (every panel
    /// in the app).
    override public init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType,
                         defer flag: Bool) {
        keyWindowNotifications = .default
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
    }

    override open var canBecomeKey: Bool { isAppActive() }

    override open func makeKey() {
        guard canBecomeKey else { return watchKeyElsewhere() }
        super.makeKey()
    }

    override open func makeKeyAndOrderFront(_ sender: Any?) {
        guard canBecomeKey else {
            orderFront(sender)
            return watchKeyElsewhere()
        }
        super.makeKeyAndOrderFront(sender)
    }

    override open func becomeKey() {
        super.becomeKey()
        stopWatching()
    }

    override open func orderOut(_ sender: Any?) {
        stopWatching()
        super.orderOut(sender)
    }

    private func watchKeyElsewhere() {
        guard keyElsewhere == nil else { return }
        keyElsewhere = MainActorObservation(NSWindow.didBecomeKeyNotification, center: keyWindowNotifications,
                                            read: { $0.object as? NSWindow }) { [weak self] window in
            guard let self, let window, window !== self, !self.isKeyWindow else { return }
            self.stopWatching()
            // Owners ignore it once the panel is closed.
            self.onKeyElsewhere?()
        }
    }

    private func stopWatching() {
        keyElsewhere = nil
    }
}
