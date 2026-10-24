import AppKit
import CmuxNextCompat

/// The app's one listener for the system notices its windows react to: the keyboard's moves (a
/// window's inactive look, ``WindowKeyFamily``) and the moments a window's status indicators check
/// themselves again (``WindowIndicatorResync``) (P3).
///
/// Each notice is observed once per app, only while some window needs it, and goes only to the
/// windows it concerns:
///
/// - A key, main or activation change is read once per main-actor turn (a Cmd-Tab posts 3 to 6
///   notices), and only the windows that held the keyboard at the last read or hold it now check
///   their look: no other window's look can change (``checkKey()``).
/// - The inactive-dim setting redraws every window with a material view (it is app-wide).
/// - A window becoming main resyncs that window's indicators alone; a window's occlusion change
///   pays the resync that window owes. Both are found by the window's identity (O(1) per notice).
/// - An app-wide moment (activation, unhide, wake, screens wake, a session switch back) goes to
///   each window holding an indicator, which resyncs when it is on screen and otherwise owes one.
///
/// Every window's key tracker used to observe seven app-wide notices itself, and every window with
/// an indicator its own six: a Cmd-Tab woke one observer per window per notice.
///
/// A window takes part through a ``WindowMomentSubscription`` it holds: releasing it (its last
/// material view or indicator left, or the window was freed with them still in it) takes the window
/// out at once, and the last one out stops the observers, so an app with no such window costs
/// nothing.
///
/// The cmux app makes one, held by its application object (``WindowMomentsHosting``), before its
/// first window. Tests make their own on their own centers, with their own key window, activation
/// state, turn runner and visibility, and pass it to ``WindowKeyFamily/of(_:moments:)``:
///
/// ```swift
/// let moments = WindowMoments(app: center, workspace: workspace, keyWindow: { nil }, nextTurn: { pending.append($0) })
/// let family = WindowKeyFamily.of(window, moments: moments)
/// ```
@MainActor
public final class WindowMoments {
    /// Where the app's and its windows' notices arrive.
    private let app: NotificationCenter
    /// Where the Mac's wake and session notices arrive.
    private let workspace: NotificationCenter
    /// The key window now (`NSApp.keyWindow`).
    private let keyWindow: @MainActor () -> NSWindow?
    /// The main window now (`NSApp.mainWindow`): it holds the keyboard for a parentless page window.
    private let mainWindow: @MainActor () -> NSWindow?
    /// Whether this app is active (`NSApp.isActive`).
    private let isAppActive: @MainActor () -> Bool
    /// Runs `work` on the next main-actor turn (a resign posts before the next window becomes key).
    let nextTurn: @MainActor (_ work: @escaping @MainActor () -> Void) -> Void
    /// Whether a window is on screen and not fully covered.
    let isWindowVisible: @MainActor (NSWindow) -> Bool

    /// A window's subscriber, held weakly (its subscription is what keeps it in), with the serial of
    /// that subscription: a later window at the same address is never taken out by the old one's.
    private struct Entry<Subscriber: AnyObject> {
        weak var subscriber: Subscriber?
        let serial: UInt64
    }

    /// The windows with a material view, by window identity.
    private var families: [ObjectIdentifier: Entry<WindowKeyFamily>] = [:]
    /// The windows holding a status indicator, by window identity.
    private var indicatorSets: [ObjectIdentifier: Entry<WindowIndicatorResync>] = [:]
    private var observers: [Notification.Name: MainActorObservation] = [:]
    private var lastSerial: UInt64 = 0
    /// A key read is scheduled for the next turn.
    private var keyCheckPending = false
    /// The windows that held the keyboard at the last key read.
    private var holding: Set<ObjectIdentifier> = []
    /// Windows whose tracker started since the last key read: they read it whatever moved.
    private var joined: Set<ObjectIdentifier> = []

    /// The running app's notices and state.
    public convenience init() {
        self.init(app: .default)
    }

    /// - Parameters:
    ///   - app: Where the app and window notices arrive (tests post to their own).
    ///   - workspace: Where the Mac's wake and session notices arrive.
    ///   - keyWindow: The key window now.
    ///   - mainWindow: The main window now.
    ///   - isAppActive: Whether the app is active.
    ///   - nextTurn: Runs work on the next main-actor turn (tests run it themselves).
    ///   - isWindowVisible: Whether a window is on screen and not fully covered.
    init(app: NotificationCenter,
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
         mainWindow: @escaping @MainActor () -> NSWindow? = { NSApp.mainWindow },
         isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         nextTurn: @escaping @MainActor (_ work: @escaping @MainActor () -> Void) -> Void = { work in
             Task { @MainActor in work() }
         },
         isWindowVisible: @escaping @MainActor (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }) {
        self.app = app
        self.workspace = workspace
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
        self.isAppActive = isAppActive
        self.nextTurn = nextTurn
        self.isWindowVisible = isWindowVisible
    }

    /// The key, main and activation notices a window's look reads, and the dim setting.
    private static let keyNotices: Set<Notification.Name> = [
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
        NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        WindowMaterialView.inactiveDimDidChange,
    ]
    /// The moments a window's indicators resync on, from the app's center.
    private static let indicatorAppNotices: Set<Notification.Name> = [
        NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification,
        NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification,
    ]
    /// The moments a window's indicators resync on, from the Mac's workspace center.
    private static let indicatorWorkspaceNotices: Set<Notification.Name> = [
        NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
    ]

    // MARK: Subscriptions

    /// Takes `family`'s window in: it reads the keyboard on the next turn, then whenever its look
    /// may change, until the returned subscription is released.
    func subscribe(_ family: WindowKeyFamily) -> WindowMomentSubscription {
        let window = family.windowID
        let serial = nextSerial()
        families[window] = Entry(subscriber: family, serial: serial)
        joined.insert(window)
        syncObservers()
        scheduleKeyCheck()
        return WindowMomentSubscription { [weak self] in self?.endFamily(window, serial: serial) }
    }

    /// Takes `indicators`' window in: it hears its window's moments until the returned
    /// subscription is released.
    func subscribe(_ indicators: WindowIndicatorResync) -> WindowMomentSubscription {
        let window = indicators.windowID
        let serial = nextSerial()
        indicatorSets[window] = Entry(subscriber: indicators, serial: serial)
        syncObservers()
        return WindowMomentSubscription { [weak self] in self?.endIndicators(window, serial: serial) }
    }

    private func nextSerial() -> UInt64 {
        lastSerial &+= 1
        return lastSerial
    }

    private func endFamily(_ window: ObjectIdentifier, serial: UInt64) {
        guard families[window]?.serial == serial else { return }
        families[window] = nil
        joined.remove(window)
        syncObservers()
    }

    private func endIndicators(_ window: ObjectIdentifier, serial: UInt64) {
        guard indicatorSets[window]?.serial == serial else { return }
        indicatorSets[window] = nil
        syncObservers()
    }

    /// Observes exactly the notices some window needs now, each once.
    private func syncObservers() {
        var wanted: Set<Notification.Name> = []
        if !families.isEmpty { wanted.formUnion(Self.keyNotices) }
        if !indicatorSets.isEmpty { wanted.formUnion(Self.indicatorAppNotices.union(Self.indicatorWorkspaceNotices)) }
        observers = observers.filter { wanted.contains($0.key) }
        for name in wanted where observers[name] == nil {
            let center = Self.indicatorWorkspaceNotices.contains(name) ? workspace : app
            observers[name] = MainActorObservation(name, center: center,
                                                   read: { $0.object.map { ObjectIdentifier($0 as AnyObject) } }) { [weak self] sender in
                self?.arrived(name, from: sender)
            }
        }
    }

    // MARK: Dispatch

    private func arrived(_ name: Notification.Name, from sender: ObjectIdentifier?) {
        if !families.isEmpty, Self.keyNotices.contains(name) {
            if name == WindowMaterialView.inactiveDimDidChange {
                for entry in Array(families.values) { entry.subscriber?.dimDidChange() }
            } else {
                scheduleKeyCheck()
            }
        }
        guard !indicatorSets.isEmpty else { return }
        switch name {
        case NSWindow.didBecomeMainNotification:
            if let sender { indicatorSets[sender]?.subscriber?.resync() }
        case NSWindow.didChangeOcclusionStateNotification:
            if let sender { indicatorSets[sender]?.subscriber?.occlusionChanged() }
        case _ where Self.indicatorAppNotices.contains(name) || Self.indicatorWorkspaceNotices.contains(name):
            // Copied first: a resync can make a window's last indicator leave.
            for entry in Array(indicatorSets.values) { entry.subscriber?.appCameBack() }
        default:
            break
        }
    }

    private func scheduleKeyCheck() {
        guard !keyCheckPending else { return }
        keyCheckPending = true
        nextTurn { [weak self] in self?.checkKey() }
    }

    /// Reads where the keyboard is, once, and has the windows whose look may have changed check it.
    ///
    /// A window's look depends on whether the app is active, whether its family (it and the windows
    /// it owns) holds the keyboard, and whether it ever held it (``WindowMaterialView/looksInactive(appActive:familyHoldsKey:familyHeldKey:)``).
    /// A window that holds the keyboard neither at the last read nor now looks inactive exactly when
    /// it once held it, whatever the activation: its look cannot change. So only the windows that
    /// held it then, hold it now, or just started read it.
    private func checkKey() { // perf-hot: 0.5ms cmd-tab (one key read per turn of notices, the windows that held or hold the keyboard)
        keyCheckPending = false
        guard !families.isEmpty else { return }
        let now = holdingWindows()
        let active = isAppActive()
        let involved = holding.union(now).union(joined)
        holding = now
        joined.removeAll()
        for window in involved {
            families[window]?.subscriber?.keyMoved(familyHoldsKey: now.contains(window), appActive: active)
        }
    }

    /// The windows whose family holds the keyboard: the key window and the windows that own it
    /// (parent or sheet parent). Chromium can make a page window key before the fork places it as
    /// its window's child (a browser-tab workspace switch): a parentless page window acts for the
    /// main window, as `KeyWindowRole` resolves it.
    private func holdingWindows() -> Set<ObjectIdentifier> {
        guard let key = keyWindow() else { return [] }
        var windows = Set(WindowMaterialView.holders(of: key, owner: { $0.parent ?? $0.sheetParent }).map(ObjectIdentifier.init))
        if key.parent == nil, key.sheetParent == nil, Self.isChromiumPageWindow(key), let main = mainWindow() {
            windows.insert(ObjectIdentifier(main))
        }
        return windows
    }

    /// `CefNSWindow`: a Chromium page window.
    private static func isChromiumPageWindow(_ window: NSWindow) -> Bool {
        guard let pageClass = NSClassFromString("CefNSWindow") else { return false }
        return window.isKind(of: pageClass)
    }

    // MARK: Tests

    /// Whether `family`'s window is taken in now.
    func isSubscribed(_ family: WindowKeyFamily) -> Bool {
        families[family.windowID]?.subscriber === family
    }

    /// Whether `indicators`' window is taken in now.
    func isSubscribed(_ indicators: WindowIndicatorResync) -> Bool {
        indicatorSets[indicators.windowID]?.subscriber === indicators
    }
}
