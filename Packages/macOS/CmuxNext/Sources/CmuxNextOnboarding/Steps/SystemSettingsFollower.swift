import AppKit
import CmuxNextWakeups

/// Reads of the System Settings window list (the window list itself; a fake in tests).
protocol SettingsWindowReading: AnyObject {
    /// The frontmost System Settings window on screen, or nil when there is none.
    func find() async -> SettingsWindowMatch?
    /// The window `id` now.
    func read(_ id: CGWindowID) async -> SettingsWindowState
}

/// The window list, read off the main thread.
final class LiveSettingsWindowReader: SettingsWindowReading {
    func find() async -> SettingsWindowMatch? { await SystemSettingsWindow.frontWindow() }
    func read(_ id: CGWindowID) async -> SettingsWindowState { await SystemSettingsWindow.state(of: id) }
}

/// How often the follower reads the window.
enum SettingsFollowRate: Equatable {
    /// Every display frame: the window moved within the last ``SystemSettingsFollower/stillAfter``.
    case display
    /// Every ``SystemSettingsFollower/stillInterval``: the window is still, or off screen.
    case still
}

/// What paces the follower's reads (display frames and a one-shot deadline; a fake in tests).
protocol SettingsFollowPace: AnyObject {
    /// Called on each tick while running.
    var onTick: (() -> Void)? { get set }
    /// Ticks at `rate` until ``stop()`` or another rate.
    func run(_ rate: SettingsFollowRate)
    func stop()
}

/// Display frames from the panel's window ``FrameScheduler`` while the window moves; a
/// re-armed one-shot ``DemandTimer`` while it is still. Nothing ticks once stopped.
final class LiveSettingsFollowPace: SettingsFollowPace {
    var onTick: (() -> Void)?
    private var frames: FrameClient?
    private let still = DemandTimer(owner: "onboarding.helper-panel.follow-still")
    private var rate: SettingsFollowRate?
    /// The panel: the display frames come from its window's display link.
    weak var window: NSWindow?

    init() {
        frames = FrameClient(owner: "onboarding.helper-panel.follow", isAnimation: false,
                             scheduler: { [weak self] in self?.window.map(FrameScheduler.forWindow) ?? .app }) { [weak self] _ in
            self?.onTick?()
            return true
        }
    }

    func run(_ rate: SettingsFollowRate) {
        guard rate != self.rate else { return }
        self.rate = rate
        switch rate {
        case .display:
            still.cancel()
            frames?.activate()
        case .still:
            frames?.deactivate()
            armStill()
        }
    }

    /// One deadline at a time; the next is armed before the tick, so a tick that goes back
    /// to display frames cancels it.
    private func armStill() {
        still.schedule(after: SystemSettingsFollower.stillInterval) { @MainActor [weak self] in
            guard let self, rate == .still else { return }
            armStill()
            onTick?()
        }
    }

    func stop() {
        rate = nil
        frames?.deactivate()
        still.cancel()
    }
}

/// Keeps the drag panel on the System Settings window it docked to (Codex's panel
/// follows the window the same way). The app may not have the Accessibility grant
/// yet (the person is often granting it), so it reads the one window's bounds from
/// the window list, which needs no grant, instead of AX notifications.
///
/// - Moving: a read every display frame, at most one in flight (a tick while one
///   runs is skipped). A change reports ``Event/dock(_:)``; a still window reports nothing.
/// - Still for ``stillAfter``: a read every ``stillInterval``; the next change goes
///   back to display frames.
/// - Off screen (minimized, hidden, another Space): ``Event/hide`` once, then the
///   slow reads until it is back (``Event/dock(_:)``).
/// - Closed or quit: ``Event/lost`` and the reads stop.
/// - With a ``list`` (the Screenshots pane): where the pane's first list ends, from the window's
///   top. The list moves with the window, so a move keeps it; only a scroll or a new app changes
///   it. It is read again on the slow reads only, at most every ``listInterval``, one read at a
///   time; a change reports ``Event/dock(_:)`` at the window's bounds. A failed read keeps the last.
final class SystemSettingsFollower {
    /// Time without a change after which the reads slow down.
    static let stillAfter: TimeInterval = 1
    /// Time between reads of a still or off-screen window (10 Hz).
    static let stillInterval: Duration = .milliseconds(100)
    /// Time between two reads of the pane's first list, while the window is still.
    static let listInterval: TimeInterval = 0.5

    enum Event: Equatable {
        /// The window is on screen at these window-list bounds (it moved, or came back).
        case dock(CGRect)
        /// The window left the screen.
        case hide
        /// The window closed or System Settings quit.
        case lost
    }

    let reader: any SettingsWindowReading
    /// Where the pane's first list ends (the Screenshots pane only).
    let list: (any SettingsListReading)?
    private let pace: any SettingsFollowPace
    private let now: () -> TimeInterval
    var onEvent: ((Event) -> Void)?
    /// The window followed, nil while none.
    private(set) var windowID: CGWindowID?
    private var last: SettingsWindowState?
    private var lastChange: TimeInterval = 0
    /// The read in flight.
    private(set) var reading: Task<Void, Never>?
    /// Reads started (tests).
    private(set) var reads = 0
    /// System Settings' pid, for the list reads.
    private var pid: pid_t = 0
    /// The bottom of the pane's first list, in points from the window's top edge; nil while unknown.
    private(set) var listBottom: CGFloat?
    private var listReadAt: TimeInterval = 0
    /// The list read in flight.
    private(set) var listReading: Task<Void, Never>?
    /// List reads started (tests).
    private(set) var listReads = 0

    init(reader: any SettingsWindowReading, pace: any SettingsFollowPace, list: (any SettingsListReading)? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.reader = reader
        self.list = list
        self.pace = pace
        self.now = now
        pace.onTick = { [weak self] in self?.tick() }
    }

    /// Follows `window`, docked at its bounds now, its first list ending `listBottom` under its top (nil: unknown).
    func follow(_ window: SettingsWindowMatch, listBottom: CGFloat? = nil) {
        reading?.cancel()
        reading = nil
        listReading?.cancel()
        listReading = nil
        windowID = window.id
        pid = window.pid
        last = .onScreen(window.bounds)
        lastChange = now()
        self.listBottom = listBottom
        listReadAt = now()
        pace.run(.display)
    }

    func stop() {
        pace.stop()
        reading?.cancel()
        reading = nil
        listReading?.cancel()
        listReading = nil
        windowID = nil
        last = nil
        listBottom = nil
    }

    /// One paced tick: a read, unless one is in flight.
    func tick() {
        guard let id = windowID, reading == nil else { return }
        reads += 1
        let reader = reader
        // task-owner: one window list read off the main thread; stop() and follow() cancel it and drop its result.
        reading = Task { [weak self] in
            let state = await reader.read(id)
            guard let self, !Task.isCancelled, windowID == id else { return }
            reading = nil
            apply(state)
        }
    }

    private func apply(_ state: SettingsWindowState) {
        switch state {
        case .gone:
            stop()
            onEvent?(.lost)
        case .offScreen:
            pace.run(.still)
            guard last != .offScreen else { return }
            last = .offScreen
            onEvent?(.hide)
        case .onScreen(let bounds):
            guard last != state else {
                if now() - lastChange >= Self.stillAfter {
                    pace.run(.still)
                    readList(bounds)
                }
                return
            }
            last = state
            lastChange = now()
            pace.run(.display)
            onEvent?(.dock(bounds))
        }
    }

    /// One read of the pane's first list, when there is a ``list``, none is in flight and the
    /// last was ``listInterval`` ago. Called on the slow reads only.
    private func readList(_ bounds: CGRect) {
        guard let list, let id = windowID, listReading == nil, now() - listReadAt >= Self.listInterval else { return }
        listReadAt = now()
        listReads += 1
        let window = SettingsWindowMatch(id: id, bounds: bounds, pid: pid)
        // task-owner: one AX read of the pane's first list off the main thread; stop() and follow() cancel it and drop its result.
        listReading = Task { [weak self] in
            let bottom = await list.firstListBottom(in: window)
            guard let self, !Task.isCancelled, windowID == id else { return }
            listReading = nil
            guard let bottom, bottom != listBottom else { return }
            listBottom = bottom
            if case .onScreen(let current) = last { onEvent?(.dock(current)) }
        }
    }
}
