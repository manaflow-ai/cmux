import AppKit
import CmuxNextSignposts
import CmuxNextWakeups
import ObjectiveC
import CmuxNextAppearance

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
    /// The turn's first key or activation notice, while its check has not run: a check that flips the
    /// window's look times it as a `switch.app_activation`.
    private var notice: Notice?
    /// How many deferred checks it ran (tests read it: one per window per turn of notices).
    private(set) var checks = 0
    /// How many times it called a view's ``WindowMaterialView/updateInactiveTint()`` (tests read it:
    /// 0 when nothing flipped, its window's views only when this window flipped).
    private(set) var viewUpdates = 0
    /// The views it tracks now.
    var viewCount: Int { views.allObjects.count }
    /// It observes the key and activation notices (only while it has a view).
    var isObserving: Bool { !observers.isEmpty }

    private static let families = ObjectAssociation<WindowKeyFamily>()

    /// The key and activation notices it observes. A notice's code in `switch.app_activation` is its
    /// position + 1 (``SignpostName/switchAppActivation``): a window did become key 1, resign key 2,
    /// become main 3, resign main 4; the app did become active 5, resign active 6.
    // raw-observer-allow: the names startObserving() subscribes through the app's AppEvents, listed once for their codes
    private static let notices = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, // raw-observer-allow: as above
                                  NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification, // raw-observer-allow: as above
                                  NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]

    /// Whether `code` is the app's become or resign active notice.
    private static func isAppActivation(_ code: UInt8) -> Bool { code >= 5 }

    /// The first key or activation notice of a turn.
    private struct Notice {
        /// Its code (``notices``).
        let code: UInt8
        /// When it arrived (``Signposter/nowNanos()``).
        let nanos: UInt64
        /// The turn also had the app's become or resign active notice: a Cmd-Tab, not a focus move in the app.
        var appActivation = false
    }

    /// The tracker of `window`, made on first use with `environment` (a later call returns that
    /// tracker and ignores its argument).
    static func of(_ window: NSWindow, environment: WindowKeyEnvironment = .live) -> WindowKeyFamily {
        if let existing = families.value(on: window) { return existing }
        let family = WindowKeyFamily(window: window, environment: environment)
        families.set(family, on: window)
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
        observers = Self.notices.enumerated().map { position, name in
            let code = UInt8(position + 1)
            return events.subscribe(name, owner: "WindowKeyFamily") { [weak self] in self?.keyDidMove(code) }
        }
        dimWatch = environment.appearance.subscribe([.inactiveDim], owner: "WindowKeyFamily") { [weak self] in
            self?.forEachView { $0.updateInactiveTint() }
        }
        // Key changes while it did not observe: read where the keyboard is now.
        keyDidMove(nil)
    }

    private func forEachView(_ body: (WindowMaterialView) -> Void) {
        for view in views.allObjects {
            viewUpdates += 1
            body(view)
        }
    }

    /// Reads where the keyboard is once the turn's notices are in, before its commit: a resign posts
    /// before the next window becomes key, so the key window in between (nil) would flash the wash. `code` is the
    /// notice's code (``notices``), nil for the tracker's first read, which is not a key change.
    private func keyDidMove(_ code: UInt8?) { // perf-hot: 0.5ms cmd-tab (every key or activation change, once per window per turn)
        if let code {
            if notice == nil { notice = Notice(code: code, nanos: environment.switchSignposter.nowNanos()) }
            if Self.isAppActivation(code) { notice?.appActivation = true }
        }
        guard !checkPending else { return }
        checkPending = true
        environment.beforeCommit { [weak self] in self?.check() }
    }

    /// Decides whether the window looks inactive now. A check that flips it is one `switch.app_activation`
    /// slice, from the flip to the commit that shows the wash or no wash, with the turn's first notice
    /// and its age in the begin (like Chrome's tab switch, the input to the presented frame:
    /// content/browser/renderer_host/visible_time_request_trigger.h). A window whose look stays, or a check
    /// with no view left, writes none: the key change shows nothing there.
    private func check() {
        checkPending = false
        let pending = notice
        notice = nil
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
        let activation = pending.map { beginActivation($0) }
        isInactive = inactive
        forEachView { $0.updateInactiveTint() }
        if let activation {
            let signposter = environment.switchSignposter
            environment.afterCommit { outcome in signposter.end(.switchAppActivation, activation, outcome) }
        }
    }

    /// Begins the `switch.app_activation` of the check that flips the window's look for `notice`.
    private func beginActivation(_ notice: Notice) -> SignpostInterval {
        let signposter = environment.switchSignposter
        let now = signposter.nowNanos()
        let age = Double(now >= notice.nanos ? now - notice.nanos : 0) / 1_000_000
        return signposter.beginAppActivation(noticeCode: notice.code, noticeName: Self.notices[Int(notice.code) - 1].rawValue,
                                             appActivation: notice.appActivation, noticeAgeMilliseconds: age)
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }
}
