import AppKit
import ObjectiveC

/// Whether one window looks inactive (the keyboard left its family), tracked once per window.
///
/// Every ``WindowMaterialView`` in a window (the window backdrop and each pane with its own art)
/// used to observe the six app-wide key and activation notices itself and read the key window on
/// the next turn: O(material views in the session) work per Cmd-Tab or key change. Then each
/// window's tracker observed them itself: O(windows) observers woken per notice. Now the app's
/// ``WindowMoments`` hears each notice once, reads the keyboard once per main-actor turn, and asks
/// only the trackers whose look may have changed (``keyMoved(familyHoldsKey:appActive:)``); a
/// tracker calls its views only when its state flips. It lives as long as its window (an associated
/// object) and is taken into the moments only while the window has a material view: a window kept
/// alive with none (a reused panel, a swapped backdrop) costs nothing per key change.
///
/// It also holds the window's status indicators (``indicators``): a resync reaches the window whose
/// state changed, not every indicator of the app.
@MainActor
final class WindowKeyFamily {
    private weak var window: NSWindow?
    /// The window's identity, the key ``WindowMoments`` files the tracker under.
    let windowID: ObjectIdentifier
    private let moments: WindowMoments
    /// The status indicators in this window (``WindowIndicatorResync``).
    let indicators: WindowIndicatorResync
    private let views = NSHashTable<WindowMaterialView>.weakObjects()
    /// Its place in the moments, held only while it has a view.
    private var subscription: WindowMomentSubscription?
    /// The keyboard left the window's family after the family held it.
    private(set) var isInactive = false
    /// The window's family has held the keyboard since the tracker started.
    private var familyHeldKey = false
    /// How many key reads it took part in (tests read it: one per turn of notices, only for a
    /// window that held or holds the keyboard).
    private(set) var checks = 0
    /// How many times it called a view's ``WindowMaterialView/updateInactiveTint()`` (tests read it:
    /// 0 when nothing flipped, its window's views only when this window flipped).
    private(set) var viewUpdates = 0
    /// The views it tracks now.
    var viewCount: Int { views.allObjects.count }
    /// It hears the key and activation moments (only while it has a view).
    var isObserving: Bool { subscription != nil }

    private static var key: UInt8 = 0

    /// The tracker of `window`, made on first use with `moments` (a later call returns that tracker
    /// and ignores its argument).
    static func of(_ window: NSWindow, moments: WindowMoments) -> WindowKeyFamily {
        if let existing = existing(window) { return existing }
        let family = WindowKeyFamily(window: window, moments: moments)
        objc_setAssociatedObject(window, &key, family, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return family
    }

    /// The tracker of `window` in the running app: its existing one, else one made with the moments
    /// the application holds (``WindowMomentsHosting``). Nil when it has none and the application
    /// holds no moments (a package test hosting bare views).
    static func live(_ window: NSWindow) -> WindowKeyFamily? {
        if let existing = existing(window) { return existing }
        guard let host = NSApp as? any WindowMomentsHosting else { return nil }
        return of(window, moments: host.windowMoments)
    }

    /// The tracker `window` has, if any.
    static func existing(_ window: NSWindow) -> WindowKeyFamily? {
        objc_getAssociatedObject(window, &key) as? WindowKeyFamily
    }

    private init(window: NSWindow, moments: WindowMoments) {
        self.window = window
        windowID = ObjectIdentifier(window)
        self.moments = moments
        indicators = WindowIndicatorResync(window: window, moments: moments)
    }

    func add(_ view: WindowMaterialView) {
        views.add(view)
        // Key changes while it was out: the moments read where the keyboard is now, next turn.
        if subscription == nil { subscription = moments.subscribe(self) }
    }

    func remove(_ view: WindowMaterialView) {
        views.remove(view)
        // The last view left: no one reads the state, so no notice should cost a check.
        // `anyObject` finds a live view without copying the table (O(1) per remove).
        if views.anyObject == nil { subscription = nil }
    }

    /// The moments read the keyboard and this window's look may have changed: `familyHoldsKey`,
    /// the window or a window it owns holds the keyboard; `appActive`, this app is active.
    func keyMoved(familyHoldsKey holds: Bool, appActive active: Bool) {
        guard isObserving, window != nil else { return }
        checks += 1
        let inactive = WindowMaterialView.looksInactive(appActive: active, familyHoldsKey: holds,
                                                        familyHeldKey: familyHeldKey)
        if active, holds { familyHeldKey = true }
        guard inactive != isInactive else { return }
        isInactive = inactive
        forEachView { $0.updateInactiveTint() }
    }

    /// The inactive-dim setting changed: every view redraws its wash.
    func dimDidChange() {
        forEachView { $0.updateInactiveTint() }
    }

    private func forEachView(_ body: (WindowMaterialView) -> Void) {
        for view in views.allObjects {
            viewUpdates += 1
            body(view)
        }
    }
}
