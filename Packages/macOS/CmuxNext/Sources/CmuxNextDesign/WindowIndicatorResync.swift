import AppKit

/// The status indicators in one window, resynced when that window's state changes
/// (``StatusIndicatorResyncClient``). Each window's ``WindowKeyFamily`` holds one.
///
/// A resync (an indicator checks its loop and its window's visibility again, so a spinner whose
/// notice went missing turns again) used to reach every indicator of the app on every Cmd-Tab,
/// window switch, activation, unhide and wake: O(indicators in the session) per event. Now:
///
/// - the window becoming main resyncs this window's shown indicators, no other window's;
/// - an app-wide moment (activation, unhide, wake, a session switch back) resyncs this window when
///   it is on screen; off screen (covered, minimized, another Space) it owes one, paid when its own
///   occlusion change says it shows;
/// - a window resyncs at most once per main-actor turn (a Cmd-Tab posts activation, main and key in
///   one turn).
///
/// The notices are heard once per app by ``IndicatorResyncMoments``, which calls only the window
/// they concern; a set is filed there only while an indicator is in its window, so a window without
/// one costs nothing.
///
/// Only shown indicators are called: one hidden in the window (a parked workspace's row, a collapsed
/// group, an idle row that hides itself) costs nothing per event and catches up once when it shows,
/// if a resync ran meanwhile (``generation``, read by ``StatusIndicatorPlacement``).
@MainActor
final class WindowIndicatorResync {
    private weak var window: NSWindow?
    /// The window's identity, the key ``IndicatorResyncMoments`` files the set under.
    let windowID: ObjectIdentifier
    private let environment: WindowKeyEnvironment
    /// Every indicator in the window, shown or hidden (they keep it filed).
    private let members = NSHashTable<AnyObject>.weakObjects()
    /// The indicators that show now: the ones a resync calls.
    private let shown = NSHashTable<AnyObject>.weakObjects()
    /// Bumped by every resync: a hidden indicator that shows again sees whether it missed one.
    private(set) var generation: UInt64 = 0
    /// A resync ran this turn; cleared on the next turn.
    private var resyncedThisTurn = false
    /// An app-wide moment found the window off screen: it resyncs when it shows.
    private var owesResync = false
    /// How many times it called an indicator's resync (tests: per event, the shown indicators of the
    /// window whose state changed, and nothing for any other window).
    private(set) var touches = 0
    /// It hears its window's moments (filed with the app's ``IndicatorResyncMoments``, only while an
    /// indicator is in the window).
    var isObserving: Bool { environment.resyncMoments.isFiled(self) }
    /// Its window is still alive.
    var hasWindow: Bool { window != nil }

    init(window: NSWindow, environment: WindowKeyEnvironment) {
        self.window = window
        windowID = ObjectIdentifier(window)
        self.environment = environment
    }

    /// `client` moved into the window (hidden until ``show(_:)``).
    func enter(_ client: any StatusIndicatorResyncClient) {
        let first = members.anyObject == nil
        members.add(client)
        if first { environment.resyncMoments.file(self) }
    }

    /// `client` left the window.
    func leave(_ client: any StatusIndicatorResyncClient) {
        members.remove(client)
        shown.remove(client)
        // `anyObject` finds a live member without copying the table: a leave stays O(1), so a
        // window teardown or a row recycle is not O(members) per indicator.
        guard members.anyObject == nil else { return }
        environment.resyncMoments.unfile(self)
        // Nothing in the window missed the moment it owed: an indicator that enters later starts
        // current.
        owesResync = false
    }

    /// `client` shows in the window: resyncs reach it.
    func show(_ client: any StatusIndicatorResyncClient) {
        shown.add(client)
    }

    /// `client` hid in the window (its own flag or an ancestor's): resyncs pass it by.
    func hide(_ client: any StatusIndicatorResyncClient) {
        shown.remove(client)
    }

    /// The app came back (to the front, unhidden, after sleep): resync now when the window is on
    /// screen, else when it shows.
    func appCameBack() {
        guard let window else { return }
        if environment.isWindowVisible(window) { resync() } else { owesResync = true }
    }

    /// The window's occlusion changed: a resync it owes is paid once it shows.
    func occlusionChanged() {
        guard owesResync, let window, environment.isWindowVisible(window) else { return }
        resync()
    }

    /// Tells the window's shown indicators to check themselves again, once per turn.
    func resync() { // perf-hot: 0.5ms cmd-tab (the front window's shown indicators, once per turn)
        guard !resyncedThisTurn else { return }
        resyncedThisTurn = true
        environment.nextTurn { [weak self] in self?.resyncedThisTurn = false }
        owesResync = false
        generation &+= 1
        for case let client as any StatusIndicatorResyncClient in shown.allObjects {
            touches += 1
            client.statusIndicatorResync()
        }
    }
}
