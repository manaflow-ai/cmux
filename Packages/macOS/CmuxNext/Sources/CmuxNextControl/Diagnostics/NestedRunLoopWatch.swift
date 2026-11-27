import CoreFoundation
import CmuxNextCompat

/// Sees the main thread parked in a nested run of the main run loop that takes no input: a
/// `Process.waitUntilExit()`, a `RunLoop.run(until:)` or a `CFRunLoopRunInMode` in the default mode
/// called from inside a run-loop callout. Such a run sleeps and wakes like an idle app, so the
/// heartbeat (``MainThreadWatchdog``) reads it as idle and records nothing, yet no input event is
/// dequeued, so macOS marks the app "Application Not Responding" (Leo's NIGHTLY, 2026-11-09 19:17Z
/// and 19:48Z: two Dock force quits, no hang file, no `.hang` report).
///
/// The rule: the main thread entered a second level of the run loop in the default mode and stayed
/// in it past the hang threshold. AppKit's own nested event loops take input in other modes (menus
/// and `NSWindow.nextEvent(matching:)` press tracking in the event-tracking mode, `runModal` in the
/// modal-panel mode), so they are not timed. Past the threshold the watchdog thread reports it like
/// a hang, with the main thread's stack: the frames under the nested run name its caller.
///
/// Cost: one atomic add per run-loop entry and exit; a lock and one wake of the watchdog thread only
/// when a nested default-mode run starts or a reported one ends. Nothing while the app is idle.
final class NestedRunLoopWatch: Sendable {
    /// One nested run of the main run loop (the first nested level).
    struct Episode: Equatable, Sendable {
        var id: UInt64
        var startNanos: UInt64
        var reported = false
        var endNanos: UInt64?

        /// Whether this run, still open at `now`, has been parked for `hangNanos`.
        func isParked(now: UInt64, hangNanos: UInt64) -> Bool {
            endNanos == nil && !reported && now >= startNanos && now - startNanos >= hangNanos
        }
    }

    /// What the watchdog thread does with the episode now.
    enum Action: Equatable, Sendable {
        case idle
        /// Parked past the threshold: sample and report it (once).
        case report(id: UInt64, elapsedNanos: UInt64)
        /// A reported run ended: close its hang file with this duration.
        case ended(id: UInt64, durationNanos: UInt64)
    }

    /// Levels of the main run loop the observer saw entered and not exited (main thread writes).
    private let depth = Atomic<Int>(0)
    private let nextID = Atomic<UInt64>(1)
    private let episode = Mutex<Episode?>(nil)

    /// The main thread is already inside a run of the main run loop when watching starts.
    func start(insideRun: Bool) {
        depth.store(insideRun ? 1 : 0, ordering: .relaxed)
    }

    /// Main thread, at a run-loop entry. True when a nested default-mode run began (wake the watchdog
    /// thread so it times it). `inDefaultMode` is read only for the first nested level.
    func entered(now: UInt64, inDefaultMode: () -> Bool) -> Bool {
        let level = depth.add(1, ordering: .relaxed).newValue
        guard level == 2, inDefaultMode() else { return false }
        let started = Episode(id: nextID.add(1, ordering: .relaxed).oldValue, startNanos: now)
        episode.withLock { $0 = started }
        return true
    }

    /// Main thread, at a run-loop exit. True when a reported run ended (wake the watchdog thread so it
    /// closes the hang file).
    func exited(now: UInt64) -> Bool {
        let level = depth.subtract(1, ordering: .relaxed).newValue
        if level < 0 { depth.store(0, ordering: .relaxed) }
        guard level == 1 else { return false }
        return episode.withLock { episode in
            guard var open = episode, open.endNanos == nil else { return false }
            guard open.reported else {
                episode = nil
                return false
            }
            open.endNanos = now
            episode = open
            return true
        }
    }

    /// Watchdog thread: what to do now; marks a report as made and drops an ended run.
    func take(now: UInt64, hangNanos: UInt64) -> Action {
        episode.withLock { episode in
            guard var open = episode else { return .idle }
            if let end = open.endNanos {
                episode = nil
                return .ended(id: open.id, durationNanos: end >= open.startNanos ? end - open.startNanos : 0)
            }
            guard open.isParked(now: now, hangNanos: hangNanos) else { return .idle }
            open.reported = true
            episode = open
            return .report(id: open.id, elapsedNanos: now - open.startNanos)
        }
    }

    /// Watchdog thread: how long it may park before the open run would cross `hangNanos`; nil when
    /// there is nothing to time (it parks until the main thread wakes it).
    func parkLimit(now: UInt64, hangNanos: UInt64) -> UInt64? {
        episode.withLock { episode in
            guard let open = episode else { return nil }
            if open.endNanos != nil { return 1 }
            guard !open.reported else { return nil }
            let due = open.startNanos &+ hangNanos
            return due > now ? due - now : 1
        }
    }

    /// The hang file's key for a nested run: counts down from the top, apart from heartbeat beats.
    static func episodeKey(_ id: UInt64) -> UInt64 { .max - id }

    /// Whether the main run loop's current mode is the default mode (main thread, inside a run).
    static func mainLoopInDefaultMode() -> Bool {
        guard let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) else { return false }
        return mode == .defaultMode
    }
}
