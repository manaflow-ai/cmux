public import AppKit
public import CmuxNextWakeups

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
///
/// The watch is one subscription on the app's ``AppEvents`` (one NotificationCenter observer per
/// notice for the whole app, as Chromium's app controller observes NSApp notices once:
/// chrome/browser/app_controller_mac.mm), held only while the panel is shown without the keys.
open class ActiveAppKeyPanel: NSPanel {
    /// Whether the app is active (tests inject their own per panel).
    public var isAppActive: () -> Bool = { NSApp?.isActive ?? false }

    /// Another window of the app took the keys while this panel was shown
    /// without them.
    public var onKeyElsewhere: (() -> Void)?
    /// Where any window's key notice arrives: the composition root injects the app's one
    /// (`AppServices.appEvents`); a panel it did not set up observes `NotificationCenter.default`
    /// through its own.
    public lazy var appEvents = AppEvents(center: .default)
    private var keyElsewhere: EventSubscription?

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
        // This panel becoming key is a key notice too: it is key then, so only another window's passes.
        keyElsewhere = appEvents.subscribe(NSWindow.didBecomeKeyNotification, owner: "ActiveAppKeyPanel") { [weak self] in
            guard let self, !self.isKeyWindow else { return }
            self.stopWatching()
            // Owners ignore it once the panel is closed.
            self.onKeyElsewhere?()
        }
    }

    private func stopWatching() {
        keyElsewhere?.cancel()
        keyElsewhere = nil
    }

    /// Whether the panel waits for another window to take the keys (tests).
    var isWatchingKeyElsewhere: Bool { keyElsewhere != nil }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            stopWatching()
        }
    }
}
