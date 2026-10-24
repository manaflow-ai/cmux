import AppKit
import CmuxNextCompat

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
///   occlusion notice says it shows;
/// - a window resyncs at most once per main-actor turn (a Cmd-Tab posts activation, main and key in
///   one turn).
///
/// Only shown indicators are called: one hidden in the window (a parked workspace's row, a collapsed
/// group, an idle row that hides itself) costs nothing per event and catches up once when it shows,
/// if a resync ran meanwhile (``generation``, read by ``StatusIndicatorPlacement``). It observes only
/// while an indicator is in the window, so a window without one costs nothing.
@MainActor
final class WindowIndicatorResync {
    private weak var window: NSWindow?
    private let environment: WindowKeyEnvironment
    /// Every indicator in the window, shown or hidden (they keep it observing).
    private let members = NSHashTable<AnyObject>.weakObjects()
    /// The indicators that show now: the ones a resync calls.
    private let shown = NSHashTable<AnyObject>.weakObjects()
    private var observers: [MainActorObservation] = []
    /// Bumped by every resync: a hidden indicator that shows again sees whether it missed one.
    private(set) var generation: UInt64 = 0
    /// A resync ran this turn; cleared on the next turn.
    private var resyncedThisTurn = false
    /// An app-wide moment found the window off screen: it resyncs when it shows.
    private var owesResync = false
    /// How many times it called an indicator's resync (tests: per event, the shown indicators of the
    /// window whose state changed, and nothing for any other window).
    private(set) var touches = 0
    /// It observes the window's and the app's notices (only while an indicator is in the window).
    var isObserving: Bool { !observers.isEmpty }

    init(window: NSWindow, environment: WindowKeyEnvironment) {
        self.window = window
        self.environment = environment
    }

    /// `client` moved into the window (hidden until ``show(_:)``).
    func enter(_ client: any StatusIndicatorResyncClient) {
        members.add(client)
        if observers.isEmpty { startObserving() }
    }

    /// `client` left the window.
    func leave(_ client: any StatusIndicatorResyncClient) {
        members.remove(client)
        shown.remove(client)
        if members.allObjects.isEmpty { observers.removeAll() }
    }

    /// `client` shows in the window: resyncs reach it.
    func show(_ client: any StatusIndicatorResyncClient) {
        shown.add(client)
    }

    /// `client` hid in the window (its own flag or an ancestor's): resyncs pass it by.
    func hide(_ client: any StatusIndicatorResyncClient) {
        shown.remove(client)
    }

    private func startObserving() {
        guard let window else { return }
        let app = environment.center, workspace = environment.workspaceCenter
        observers = [
            MainActorObservation(NSWindow.didBecomeMainNotification, object: window, center: app) { [weak self] in self?.resync() },
            MainActorObservation(NSWindow.didChangeOcclusionStateNotification, object: window, center: app) { [weak self] in
                self?.occlusionChanged()
            },
        ]
        let moments: [(NotificationCenter, Notification.Name)] = [
            (app, NSApplication.didBecomeActiveNotification), (app, NSApplication.didUnhideNotification),
            (workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        observers += moments.map { center, name in
            MainActorObservation(name, center: center) { [weak self] in self?.appCameBack() }
        }
    }

    /// The app came back (to the front, unhidden, after sleep): resync now when the window is on
    /// screen, else when it shows.
    private func appCameBack() {
        guard let window else { return }
        if environment.isWindowVisible(window) { resync() } else { owesResync = true }
    }

    private func occlusionChanged() {
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
