import AppKit
import CmuxNextSignposts
import CmuxNextWakeups
import ObjectiveC

/// Whether one window looks inactive (the keyboard left its family), tracked once per window.
///
/// Every ``WindowMaterialView`` in a window (the window backdrop and each pane with its own art)
/// used to observe the six app-wide key and activation notices itself and read the key window on
/// the next turn: O(material views in the session) work per Cmd-Tab or key change. The window's
/// tracker subscribes to them once through the app's injected ``AppEvents`` (one NotificationCenter
/// observer per notice for all windows' trackers), decides once per main-actor turn (a Cmd-Tab
/// posts 3 to 6 notices), and calls only its views, only when the state flips. It lives as long as
/// its window (an associated object), and it observes only while the window has a material view:
/// a window kept alive with none (a reused panel, a swapped backdrop) costs nothing per key change.
@MainActor
final class WindowKeyFamily {
    private weak var window: NSWindow?
    private let environment: WindowKeyEnvironment
    private let views = NSHashTable<WindowMaterialView>.weakObjects()
    private var observers: [EventSubscription] = []
    /// `appearance.inactiveWindowDim` changes (only while it has a view).
    private var dimWatch: AppearanceSignals.Subscription?
    /// The injected app events, or this window's own when none was injected.
    private lazy var events = environment.events ?? AppEvents(center: .default)
    /// The keyboard left the window's family after the family held it.
    private(set) var isInactive = false
    /// The window's family has held the keyboard since the tracker started.
    private var familyHeldKey = false
    /// A deferred check is scheduled and has not run: later notices in the same turn need no
    /// check of their own (the check reads the keyboard when it runs, after all of them).
    private var checkPending = false
    /// The `switch.app_activation` the turn's first key or activation notice began; the commit after
    /// the turn's check ends it.
    private var activation: SignpostInterval?
    /// How many deferred checks it ran (tests read it: one per window per turn of notices).
    private(set) var checks = 0
    /// How many times it called a view's ``WindowMaterialView/updateInactiveTint()`` (tests read it:
    /// 0 when nothing flipped, its window's views only when this window flipped).
    private(set) var viewUpdates = 0
    /// The views it tracks now.
    var viewCount: Int { views.allObjects.count }
    /// It observes the key and activation notices (only while it has a view).
    var isObserving: Bool { !observers.isEmpty }

    private static var key: UInt8 = 0

    /// The tracker of `window`, made on first use with `environment` (a later call returns that
    /// tracker and ignores its argument).
    static func of(_ window: NSWindow, environment: WindowKeyEnvironment = .live) -> WindowKeyFamily {
        if let existing = objc_getAssociatedObject(window, &key) as? WindowKeyFamily { return existing }
        let family = WindowKeyFamily(window: window, environment: environment)
        objc_setAssociatedObject(window, &key, family, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return family
    }

    private init(window: NSWindow, environment: WindowKeyEnvironment) {
        self.window = window
        self.environment = environment
    }

    func add(_ view: WindowMaterialView) {
        views.add(view)
        if observers.isEmpty { startObserving() }
    }

    func remove(_ view: WindowMaterialView) {
        views.remove(view)
        // The last view left: no one reads the state, so no notice should cost a check.
        if views.allObjects.isEmpty {
            observers.removeAll()
            dimWatch = nil
        }
    }

    private func startObserving() {
        // Any window's key change and the app's activation: the keyboard moving into this
        // window's own Chromium page window resigns this window's key, and leaving from that page
        // window to another app posts nothing on this window.
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        observers = names.enumerated().map { position, name in
            events.subscribe(name, owner: "WindowKeyFamily") { [weak self] in self?.keyDidMove(name, code: UInt64(position + 1)) }
        }
        dimWatch = environment.appearance.subscribe([.inactiveDim], owner: "WindowKeyFamily") { [weak self] in
            self?.forEachView { $0.updateInactiveTint() }
        }
        // Key changes while it did not observe: read where the keyboard is now.
        keyDidMove(nil, code: 0)
    }

    private func forEachView(_ body: (WindowMaterialView) -> Void) {
        for view in views.allObjects {
            viewUpdates += 1
            body(view)
        }
    }

    /// Reads where the keyboard is on the next main-actor turn: a resign posts before the next
    /// window becomes key, so the key window in between (nil) would flash the wash.
    ///
    /// The turn's first notice begins this window's `switch.app_activation`, and the commit after the
    /// check ends it: one async slice per window the key change touched, from the notice to the frame
    /// that shows its wash or no wash, like Chrome's tab switch slice from the input to the presented
    /// frame (content/browser/renderer_host/visible_time_request_trigger.h). The begin's message is the
    /// notice's name and its `arg0` the notice's `code`, its position + 1 in ``startObserving()``'s list:
    /// a window did become key 1, resign key 2, become main 3, resign main 4; the app did become active 5,
    /// resign active 6. `notice` is nil for the tracker's first read, which is not a key change and takes
    /// no interval.
    private func keyDidMove(_ notice: Notification.Name?, code: UInt64) { // perf-hot: 0.5ms cmd-tab (every key or activation change, once per window per turn)
        if let notice, activation == nil {
            activation = environment.switchSignposter.begin(.switchAppActivation, notice.rawValue, arg0: code)
        }
        guard !checkPending else { return }
        checkPending = true
        // Held for one turn: the check ends the interval its notice began, even after the window went away.
        environment.nextTurn { self.check() }
    }

    private func check() {
        checkPending = false
        defer { endActivation() }
        guard isObserving, let window else { return }
        checks += 1
        let key = environment.keyWindow()
        // Chromium can make a page window key before the fork places it as this window's
        // child (a browser-tab workspace switch): a parentless page window acts for the main
        // window, as `KeyWindowRole` resolves it.
        let parentlessPage = key.map { $0.parent == nil && $0.sheetParent == nil && Self.isChromiumPageWindow($0) } ?? false
        let holds = WindowMaterialView.family(of: window, holds: key, owner: { $0.parent ?? $0.sheetParent })
            || (parentlessPage && window.isMainWindow)
        let active = environment.isAppActive()
        let inactive = WindowMaterialView.looksInactive(appActive: active, familyHoldsKey: holds,
                                                        familyHeldKey: familyHeldKey)
        if active, holds { familyHeldKey = true }
        guard inactive != isInactive else { return }
        isInactive = inactive
        forEachView { $0.updateInactiveTint() }
    }

    /// Ends the open `switch.app_activation` at the commit that ends this turn.
    private func endActivation() {
        guard let interval = activation else { return }
        activation = nil
        let signposter = environment.switchSignposter
        environment.afterCommit { outcome in signposter.end(.switchAppActivation, interval, outcome) }
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }
}
