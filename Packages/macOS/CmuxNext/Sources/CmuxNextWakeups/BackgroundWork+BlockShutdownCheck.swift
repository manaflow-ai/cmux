#if DEBUG || CMUX_BLOCKING_CHECKS
import os
#endif

extension BackgroundWork {
    /// How long one ``ShutdownBehavior/blockShutdown`` item may run before Debug records it: quit waits for
    /// every such item, so one must be a single bounded write (< 50 ms, an atomic replace), never a scan or a
    /// migration. 250 ms is the main-thread lag that hang reports start at.
    public static let blockShutdownLimit: Duration = .milliseconds(250)

    /// The most overruns one ``BackgroundWork`` keeps (a bound: the oldest are dropped).
    static let overrunLimit = 32

    /// A block-shutdown item that ran longer than ``blockShutdownLimit``.
    public struct BlockShutdownOverrun: Sendable, Equatable {
        /// Where it was started: `<module>/<file>.swift:<line>` (no path, no user text).
        public var site: String
        /// How long it ran.
        public var duration: Duration

        /// Makes the value from its parts.
        public init(site: String, duration: Duration) {
            self.site = site
            self.duration = duration
        }
    }

    /// The call site of an item, named only when it overruns.
    struct CallSite: Sendable {
        let fileID: StaticString
        let line: UInt
    }

    /// The block-shutdown items that ran longer than ``blockShutdownLimit``, oldest first (Debug and bench
    /// builds record them; other builds keep this empty).
    public var blockShutdownOverruns: [BlockShutdownOverrun] {
        state.withLock { $0.overruns }
    }

    /// The start of a block-shutdown item's run, or nil in builds without the check.
    func blockShutdownStarted() -> UInt64? {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        return uptimeNanos()
        #else
        return nil
        #endif
    }

    /// Records the item at `site` when it ran longer than ``blockShutdownLimit`` since `start`.
    func blockShutdownEnded(_ site: CallSite, since start: UInt64?) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        guard let start else { return }
        let elapsed = uptimeNanos() &- start
        let duration = Duration.nanoseconds(Int64(clamping: elapsed))
        guard duration > Self.blockShutdownLimit else { return }
        let overrun = BlockShutdownOverrun(site: "\(site.fileID):\(site.line)", duration: duration)
        state.withLock { state in
            if state.overruns.count == Self.overrunLimit { state.overruns.removeFirst() }
            state.overruns.append(overrun)
        }
        Logger(subsystem: "com.cmuxterm.app.next", category: "work").fault(
            "blockShutdown item at \(overrun.site, privacy: .public) ran \(elapsed / 1_000_000, privacy: .public) ms (limit 250 ms): quit waits for it; make it one bounded write, or use skipOnShutdown or continueOnShutdown"
        )
        #endif
    }
}
