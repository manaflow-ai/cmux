public import AppKit
import CmuxNextCompat
import ObjectiveC

/// One window's main and occlusion notices, observed once per window for every view that follows
/// them.
///
/// Views that follow their window's main state or occlusion (each pane's tab strip, each agent
/// pane's visibility probe) used to observe the window's notices themselves: one NotificationCenter
/// observer per view and notice, so a window with N such views ran N blocks per main or occlusion
/// change. The window's ``WindowNotices`` observes `didBecomeMain`, `didResignMain` and
/// `didChangeOcclusionState` once and calls only the followers that asked for the notice
/// (plans/cmux-next/PATTERNS.md P3, like ``WindowKeyFamily`` for key state). It lives as long as its
/// window (an associated object), so no process-wide instance exists, and it observes only while
/// something follows the window: when the last follower leaves (or a released follower is found on
/// the next notice), its observations end.
///
/// ```swift
/// let next = window.map { WindowNotices.of($0) }
/// if next !== notices {
///     notices?.remove(self)
///     next?.add(self, for: [.occlusionChanged])
///     notices = next
/// }
/// ```
///
/// Tests pass their own `NotificationCenter` to ``of(_:center:)`` and post on it; each center gets
/// its own instance for the window, so a test's center never shares observations with the app's.
@MainActor
public final class WindowNotices {
    /// One follower and the notices it asked for. A Swift `weak` reference, not `NSHashTable`:
    /// `NSHashTable.allObjects` loads each entry through `objc_loadWeak`, which autoreleases it, so a
    /// read kept every follower alive until the autorelease pool drained, and a follower released
    /// in the same run-loop turn still counted as following. A Swift weak load returns a +1
    /// reference released at the end of its scope (`objc_loadWeakRetained` for an Objective-C
    /// follower such as an `NSView`), so a read never makes a follower live longer.
    private struct Entry {
        weak var follower: (any WindowNoticesFollower)?
        let notices: Set<WindowNotice>
    }

    /// The window's instances, one per center (``of(_:center:)``); the window owns it.
    private final class ByCenter {
        var instances: [ObjectIdentifier: WindowNotices] = [:]

        // cx-t7hu: nonisolated, so the window's release runs no runtime hop; an implicit deinit is
        // isolated in this target.
        nonisolated deinit {}
    }

    private weak var window: NSWindow?
    /// The center the window's notices arrive on; held, so its identity keys this instance while
    /// the window lives.
    private let center: NotificationCenter
    private var followers: [Entry] = []
    /// The window's three observations; each stops when released.
    private var observations: [MainActorObservation] = []

    /// Whether it observes the window's notices now (only while something follows the window).
    var isObserving: Bool { !observations.isEmpty }

    private static var key: UInt8 = 0

    /// The window's notices on `center`, made on first use.
    ///
    /// Each center gets its own instance for the window, so a follower always observes the center
    /// it names: a later caller with another center gets a new instance, never one made for a
    /// different center.
    ///
    /// - Parameters:
    ///   - window: The window whose main and occlusion notices to follow.
    ///   - center: The center to observe (default `NotificationCenter.default`, where AppKit posts the
    ///     window's notices; tests pass their own).
    /// - Returns: The window's instance for `center`.
    public static func of(_ window: NSWindow, center: NotificationCenter = .default) -> WindowNotices {
        let byCenter: ByCenter
        if let existing = objc_getAssociatedObject(window, &key) as? ByCenter {
            byCenter = existing
        } else {
            byCenter = ByCenter()
            objc_setAssociatedObject(window, &key, byCenter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let id = ObjectIdentifier(center)
        if let existing = byCenter.instances[id] { return existing }
        let notices = WindowNotices(window: window, center: center)
        byCenter.instances[id] = notices
        return notices
    }

    private init(window: NSWindow, center: NotificationCenter) {
        self.window = window
        self.center = center
    }

    // cx-t7hu: nonisolated, so the window's release runs no runtime hop; an implicit deinit is
    // isolated in this target. The observations (MainActorObservation) are removed on the
    // releasing thread.
    nonisolated deinit {}

    /// Starts calling `follower` for `notices` of this window (a follower already in the list gets
    /// the new set), and starts observing the window if nothing followed it.
    ///
    /// - Parameters:
    ///   - follower: The follower to call; held weakly.
    ///   - notices: The notices it is called for.
    public func add(_ follower: any WindowNoticesFollower, for notices: Set<WindowNotice>) {
        followers.removeAll { $0.follower == nil || $0.follower === follower }
        followers.append(Entry(follower: follower, notices: notices))
        startObservingIfNeeded()
    }

    /// Stops calling `follower`; when nothing follows the window any more, stops observing it.
    ///
    /// - Parameter follower: The follower to drop.
    public func remove(_ follower: any WindowNoticesFollower) {
        followers.removeAll { $0.follower === follower }
        stopObservingIfUnfollowed()
    }

    private func startObservingIfNeeded() {
        guard observations.isEmpty, let window else { return }
        let names: [(name: Notification.Name, notice: WindowNotice)] = [
            (NSWindow.didBecomeMainNotification, .becameMain),
            (NSWindow.didResignMainNotification, .resignedMain),
            (NSWindow.didChangeOcclusionStateNotification, .occlusionChanged),
        ]
        observations = names.map { entry in
            let notice = entry.notice
            return MainActorObservation(entry.name, object: window, center: center) { [weak self] in self?.received(notice) }
        }
    }

    /// Drops released followers; with none left, no notice should cost a block.
    private func stopObservingIfUnfollowed() {
        followers.removeAll { $0.follower == nil }
        if followers.isEmpty { observations.removeAll() }
    }

    private func received(_ notice: WindowNotice) {
        deliver(notice)
        stopObservingIfUnfollowed()
    }

    /// Calls the live followers that asked for `notice`. A separate function, so the strong
    /// references it takes end before ``stopObservingIfUnfollowed()`` looks for released followers.
    private func deliver(_ notice: WindowNotice) {
        let targets = followers.compactMap { $0.notices.contains(notice) ? $0.follower : nil }
        for follower in targets { follower.windowNoticed(notice) }
    }
}
