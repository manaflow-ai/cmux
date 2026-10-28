import AppKit
import CmuxNextCompat
import CmuxNextSignposts
import CmuxNextWakeups
import CmuxNextAppearance

/// What ``WindowKeyFamily`` reads about the keyboard and when it decides: the live app by
/// default, a test's own events, key window, activation state and turn runner otherwise.
@MainActor
struct WindowKeyEnvironment {
    /// The app's events the key and activation notices arrive through, injected by the composition
    /// root (``WindowMaterialView/observeKeyFamily(of:through:)``). Nil for a window it did not set
    /// up: that window's tracker observes `NotificationCenter.default` itself.
    var events: AppEvents?
    /// Where `appearance.inactiveWindowDim` changes arrive (the app's ``AppearanceSignals``).
    var appearance: AppearanceSignals = DesignSettings.shared.signals
    /// The key window now (`NSApp.keyWindow`).
    var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }
    /// Whether this app is active (`NSApp.isActive`).
    var isAppActive: @MainActor () -> Bool = { NSApp.isActive }
    /// Runs a key change's check once this turn's notices are in, before its Core Animation commit: a block on
    /// the main run loop (``MainRunLoopBlock``), which wakes the loop and runs at its blocks stage, ahead of the
    /// before-waiting commit. A resign posts before the next window becomes key in the same turn; the wash the
    /// check decides shows in the commit after it, and the commit boundary the check asks for is still ahead,
    /// as Chromium repaints a widget's activation in the change's own task
    /// (`Widget::OnNativeWidgetActivationChanged`, ui/views/widget/widget.cc). A notice posted inside a
    /// before-waiting callout gets its check on the pass the wake starts. Tests run the checks themselves.
    var beforeCommit: @MainActor (_ check: @escaping @MainActor () -> Void) -> Void = { check in
        MainRunLoopBlock.perform(check)
    }

    /// Takes a `switch.app_activation` interval for each window whose look a turn of key or activation
    /// notices flips (``Signposter/switch``; tests pass one on their own trace runtime).
    var switchSignposter: Signposter = .switch
    /// Runs `body` after the Core Animation commit that ends this main run-loop turn (``CommitBoundary``),
    /// where a check's `switch.app_activation` ends. Tests fire the boundaries themselves.
    var afterCommit: @MainActor (_ body: @escaping @MainActor (CommitBoundary.Outcome) -> Void) -> Void = { body in
        CommitBoundary().after(body)
    }

    /// The running app.
    static var live: WindowKeyEnvironment { WindowKeyEnvironment() }
}
