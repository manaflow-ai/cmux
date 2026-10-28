public import AppKit
public import CmuxNextWakeups

/// The app in the visibility tree: the root every window's node hangs under
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section B: app > window > workspace > pane > tab).
///
/// A hidden app (Cmd-H) is ``Visibility/hidden``; sleeping displays are ``Visibility/occluded``:
/// laid out, but nobody sees it. Chromium's browser process hides every WebContents of a hidden
/// app the same way (`chrome/browser/app_controller_mac.mm` observes the NSApp hide notices once,
/// and each `WebContentsImpl::UpdateWebContentsVisibility` follows).
///
/// It reads the notices through the app's injected ``AppEvents``, one observer per name for the
/// whole app. The composition root makes the one instance (`AppServices.appVisibility`); tests
/// make their own on their own centers.
@MainActor public final class AppVisibilitySource {
    /// The app's node; a window's node is its child (``WindowVisibilitySource``).
    public let node: VisibilityNode
    /// The app is hidden (`NSApplication.didHideNotification` came last).
    public private(set) var isAppHidden: Bool
    /// The displays sleep (``DisplaySleepWatch``: the screens' notices, and the displays' real state
    /// on a system wake, a display change and at creation).
    public private(set) var screensAsleep: Bool
    /// Whether one of the app's windows shows; ``windowNode(_:name:)`` tracks each window.
    public let shownWindows = ShownWindows()
    /// The notices it follows; kept here, as a subscription holds its fan-out only weakly.
    private let appEvents: AppEvents
    /// The displays' sleep, which keeps the workspace's events.
    private let displays: DisplaySleepWatch
    private var subscriptions: [EventSubscription] = []

    /// - Parameters:
    ///   - appEvents: The app's notices (`NSApplication.didHideNotification`, `didUnhideNotification`,
    ///     `didChangeScreenParametersNotification`).
    ///   - workspaceEvents: The fan-out on `NSWorkspace.shared.notificationCenter`, where the
    ///     display sleep and wake and the system wake notices are posted.
    ///   - isAppHidden: Whether the app is hidden now (`NSApp.isHidden`).
    ///   - displaysAsleep: Whether every display sleeps now (``DisplaySleepWatch/everyDisplayAsleep()``
    ///     from the composition root; tests pass their own).
    ///   - uptime: The clock of the tree's `hiddenSince`.
    ///   - workCounts: Where the tree counts its work (`debug.layout_counters`); nil counts nothing.
    public init(appEvents: AppEvents, workspaceEvents: AppEvents, isAppHidden: Bool,
                displaysAsleep: @escaping DisplaySleepWatch.Probe,
                uptime: @escaping VisibilityNode.Uptime = VisibilityNode.systemUptime,
                workCounts: VisibilityWorkCounts? = nil) {
        let owner = "AppVisibilitySource"
        let displays = DisplaySleepWatch(workspaceEvents: workspaceEvents, appEvents: appEvents, owner: owner, probe: displaysAsleep)
        self.isAppHidden = isAppHidden
        self.appEvents = appEvents
        self.displays = displays
        screensAsleep = displays.asleep
        node = VisibilityNode(root: "app", own: AppVisibilitySource.visibility(appHidden: isAppHidden, screensAsleep: displays.asleep),
                              uptime: uptime, workCounts: workCounts)
        subscriptions = [
            // raw-observer-allow: an AppEvents subscription, the recipe R-notif asks for (the app's one observer per notice); only the notice's name matches
            appEvents.subscribe(NSApplication.didHideNotification, owner: owner) { [weak self] in self?.setHidden(true) },
            // raw-observer-allow: an AppEvents subscription, the recipe R-notif asks for (the app's one observer per notice); only the notice's name matches
            appEvents.subscribe(NSApplication.didUnhideNotification, owner: owner) { [weak self] in self?.setHidden(false) },
        ]
        displays.onChange = { [weak self] asleep in self?.setAsleep(asleep) }
    }

    /// `window`'s node (``WindowVisibilitySource``) under the app's, counted in ``shownWindows``.
    /// The window's owner calls it once, before any view reaches the window.
    public func windowNode(_ window: NSWindow, name: String) -> VisibilityNode {
        let windowNode = WindowVisibilitySource.of(window, name: name, app: node).node
        shownWindows.track(windowNode)
        return windowNode
    }

    /// The app's state from its two facts: hidden wins over asleep.
    nonisolated public static func visibility(appHidden: Bool, screensAsleep: Bool) -> Visibility {
        if appHidden { return .hidden }
        return screensAsleep ? .occluded : .visible
    }

    private func setHidden(_ hidden: Bool) {
        isAppHidden = hidden
        node.set(Self.visibility(appHidden: isAppHidden, screensAsleep: screensAsleep))
    }

    private func setAsleep(_ asleep: Bool) {
        screensAsleep = asleep
        node.set(Self.visibility(appHidden: isAppHidden, screensAsleep: screensAsleep))
    }
}
