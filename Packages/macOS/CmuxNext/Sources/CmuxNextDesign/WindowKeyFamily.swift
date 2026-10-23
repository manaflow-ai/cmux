import AppKit
import CmuxNextCompat
import ObjectiveC

/// Whether one window looks inactive (the keyboard left its family), tracked once per window.
///
/// Every ``WindowMaterialView`` in a window (the window backdrop and each pane with its own art)
/// used to observe the six app-wide key and activation notices itself and read the key window on
/// the next turn: O(material views in the session) work per Cmd-Tab or key change. The window's
/// tracker observes them once, decides once, and calls only its views, only when the state flips.
/// It lives as long as its window (an associated object), so no process-wide instance exists.
@MainActor
final class WindowKeyFamily {
    private weak var window: NSWindow?
    private let environment: WindowKeyEnvironment
    private let views = NSHashTable<WindowMaterialView>.weakObjects()
    private var observers: [MainActorObservation] = []
    /// The keyboard left the window's family after the family held it.
    private(set) var isInactive = false
    /// The window's family has held the keyboard since the tracker started.
    private var familyHeldKey = false
    /// Bumped by each key change: only the latest deferred check applies.
    private var keyCheck = 0
    /// How many times it called a view's ``WindowMaterialView/updateInactiveTint()`` (tests read it:
    /// 0 when nothing flipped, its window's views only when this window flipped).
    private(set) var viewUpdates = 0
    /// The views it tracks now.
    var viewCount: Int { views.allObjects.count }

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
        // Any window's key change and the app's activation: the keyboard moving into this
        // window's own Chromium page window resigns this window's key, and leaving from that page
        // window to another app posts nothing on this window.
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        observers = names.map { name in MainActorObservation(name, center: environment.center) { [weak self] in self?.keyDidMove() } }
        observers.append(MainActorObservation(WindowMaterialView.inactiveDimDidChange, center: environment.center) { [weak self] in
            self?.forEachView { $0.updateInactiveTint() }
        })
        keyDidMove()
    }

    func add(_ view: WindowMaterialView) { views.add(view) }
    func remove(_ view: WindowMaterialView) { views.remove(view) }

    private func forEachView(_ body: (WindowMaterialView) -> Void) {
        for view in views.allObjects {
            viewUpdates += 1
            body(view)
        }
    }

    /// Reads where the keyboard is on the next main-actor turn: a resign posts before the next
    /// window becomes key, so the key window in between (nil) would flash the wash.
    private func keyDidMove() { // perf-hot: 0.5ms cmd-tab (every key or activation change, once per window)
        keyCheck += 1
        let check = keyCheck
        environment.nextTurn { [weak self] in
            guard let self, check == self.keyCheck, let window = self.window else { return }
            let key = self.environment.keyWindow()
            // Chromium can make a page window key before the fork places it as this window's
            // child (a browser-tab workspace switch): a parentless page window acts for the main
            // window, as `KeyWindowRole` resolves it.
            let parentlessPage = key.map { $0.parent == nil && $0.sheetParent == nil && Self.isChromiumPageWindow($0) } ?? false
            let holds = WindowMaterialView.family(of: window, holds: key, owner: { $0.parent ?? $0.sheetParent })
                || (parentlessPage && window.isMainWindow)
            let active = self.environment.isAppActive()
            let inactive = WindowMaterialView.looksInactive(appActive: active, familyHoldsKey: holds,
                                                            familyHeldKey: self.familyHeldKey)
            if active, holds { self.familyHeldKey = true }
            guard inactive != self.isInactive else { return }
            self.isInactive = inactive
            self.forEachView { $0.updateInactiveTint() }
        }
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }
}
