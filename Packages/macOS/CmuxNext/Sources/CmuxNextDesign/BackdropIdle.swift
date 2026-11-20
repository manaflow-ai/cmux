public import AppKit
import CmuxNextCompat
import CoreGraphics
import CmuxNextWakeups

/// When a video wallpaper asks the scheduler again about idle time (`appearance.videoWallpaperIdlePause`,
/// seconds; 0 never). Whether it is idle is the Rust scheduler's answer (`cmux_wallpaper_schedule`
/// with the seconds since any input, ``BackdropPlayback``); this only wakes the videos when that
/// answer can change, at almost no cost. The image store owns the app's one
/// (``BackdropImageStore/idle``), shared by every window's video views.
///
/// - While a video plays, one ``DemandTimer`` deadline is set for when the idle time would be
///   reached, from the window server's seconds since the last input (`CGEventSource`). Input
///   meanwhile only means the next answer is "run" again and the deadline moves on. No event
///   monitor runs while the person is at the Mac.
/// - While a video holds for idle, the first input wakes it (``BackdropNextInput``: one local and
///   one global monitor, removed on the first event; keys typed into another app reach a global
///   monitor only with Accessibility access, so a check every ``idleCheck`` wakes it too).
/// - Nothing runs while no video watches: a held or hidden video does not watch.
@MainActor
public final class BackdropIdle {
    /// How often an idle hold reads the seconds since input again, besides the one-shot monitors.
    public static let idleCheck: Duration = .seconds(30)

    private let timer: DemandTimer
    private let since: @MainActor () -> TimeInterval
    private let setting: @MainActor () -> TimeInterval
    private let settings: DesignSettings?
    private let nextInput: BackdropNextInput?
    private var watchers: [ObjectIdentifier: (idle: Bool, changed: @MainActor () -> Void)] = [:]
    /// Follows the setting while anyone watches.
    private var settingWatch: Task<Void, Never>?

    /// - Parameters:
    ///   - clock: Times the deadlines (tests step a manual one).
    ///   - sinceInput: Seconds since the last keyboard, mouse or trackpad input.
    ///   - settings: Where `appearance.videoWallpaperIdlePause` is read and followed; nil reads
    ///     `pauseAfter` only.
    ///   - pauseAfter: The setting in seconds, 0 never (tests); by default `settings`'.
    ///   - monitorsInput: Whether an idle hold adds the one-shot event monitors (tests: false).
    public init(clock: any Clock<Duration> = ContinuousClock(),
                sinceInput: @escaping @MainActor () -> TimeInterval = BackdropIdle.systemSecondsSinceInput,
                settings: DesignSettings? = .shared, pauseAfter: (@MainActor () -> TimeInterval)? = nil,
                monitorsInput: Bool = true) {
        timer = DemandTimer(owner: "backdrop-video-idle", clock: clock)
        since = sinceInput
        self.settings = settings
        setting = pauseAfter ?? { [settings] in settings?.videoWallpaperIdlePause ?? 0 }
        nextInput = monitorsInput ? BackdropNextInput() : nil
    }

    // Not an isolated deinit (its runtime hop traps when released inside an action's scope).
    nonisolated deinit {}

    /// The window server's seconds since the last input event of any kind in this login session.
    public static func systemSecondsSinceInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0) ?? .mouseMoved)
    }

    /// Seconds since the last input now.
    public var secondsSinceInput: TimeInterval { since() }

    /// The idle time the scheduler is given: the setting, infinity for 0 (never).
    public var idleAfter: TimeInterval {
        let seconds = setting()
        return seconds > 0 ? seconds : .infinity
    }

    /// Whether `owner` is watching (tests).
    public func isWatching(_ owner: AnyObject) -> Bool { watchers[ObjectIdentifier(owner)] != nil }

    /// `owner` plays (`idle` false: wake it when the idle time is reached) or holds for idle
    /// (`idle` true: wake it on the next input). `changed` asks the scheduler again.
    public func watch(_ owner: AnyObject, idle: Bool, _ changed: @escaping @MainActor () -> Void) {
        let key = ObjectIdentifier(owner)
        let was = watchers[key]?.idle
        watchers[key] = (idle, changed)
        followSetting()
        if was != idle { arm() }
    }

    /// Stops waking `owner`; the last one to leave stops everything.
    public func unwatch(_ owner: AnyObject) {
        guard watchers.removeValue(forKey: ObjectIdentifier(owner)) != nil else { return }
        guard watchers.isEmpty else { return arm() }
        timer.cancel()
        nextInput?.stop()
        settingWatch?.cancel()
        settingWatch = nil
    }

    /// Sets the one deadline (and the input wake) for what the watchers wait for.
    private func arm() {
        let limit = idleAfter
        guard !watchers.isEmpty, limit.isFinite else {
            timer.cancel()
            nextInput?.stop()
            return
        }
        if watchers.values.contains(where: \.idle) {
            nextInput?.start { [weak self] in self?.wake() }
            timer.schedule(after: Self.idleCheck) { @MainActor [weak self] in self?.wake() }
        } else {
            nextInput?.stop()
            let missing = max(limit - since(), 0)
            // A little past the limit, so the reading then is at or over it.
            timer.schedule(after: .milliseconds(Int((missing * 1000).rounded(.up)) + 50)) { @MainActor [weak self] in
                self?.wake()
            }
        }
    }

    /// Tells every watcher to ask again (each then watches with its new answer), and re-arms.
    func wake() {
        nextInput?.stop()
        for watcher in Array(watchers.values) { watcher.changed() }
        arm()
    }

    /// A changed setting wakes every watcher at once (a deadline set for the old time is moved).
    private func followSetting() {
        guard settingWatch == nil, let settings else { return }
        // task-owner: BackdropIdle.settingWatch, cancelled when the last watcher leaves
        settingWatch = Task { [weak self] in
            var first = true
            for await _ in ObservationStream({ settings.videoWallpaperIdlePause }) {
                if first { first = false; continue }
                self?.wake()
            }
        }
    }
}

/// The next keyboard, mouse or trackpad input, once: a local and a global event monitor that
/// both go on the first event. Only an idle video wallpaper waits for it.
@MainActor
final class BackdropNextInput {
    private var monitors: [Any] = []

    /// Calls `input` on the next event (anywhere in the session for mouse events; keys in other
    /// apps need Accessibility access).
    func start(_ input: @escaping @MainActor () -> Void) {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                           .scrollWheel, .keyDown, .flagsChanged]
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            // main-proof: AppKit calls local event monitors on the main thread, in its event dispatch.
            MainActor.assumeIsolated { self?.fire(input) }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            // main-proof: AppKit calls global event monitors on the main thread.
            MainActor.assumeIsolated { self?.fire(input) }
        }
        monitors = [local, global].compactMap { $0 }
    }

    private func fire(_ input: @MainActor () -> Void) {
        guard !monitors.isEmpty else { return }
        stop()
        input()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }
}
