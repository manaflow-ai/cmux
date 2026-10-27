import Foundation
import CmuxNextCompat

extension MainThreadWatchdog {
    /// The watchdog's thresholds and switches (``MainThreadWatchdog/configuration``).
    public struct Configuration: Sendable {
        public var threshold: Duration
        public var capacity: Int
        public var sampleStacks: Bool
        public var logStalls: Bool
        /// A stall still running this long is a hang: the watchdog thread
        /// reports it (``MainThreadWatchdog/onHang``) WHILE it runs, since a
        /// hang that never ends is never recorded as a stall. Default 2 s.
        public var hangThreshold: Duration
        /// At most one hang report per this interval (default 5 min).
        public var hangReportInterval: Duration
        /// Debug builds: a hang still running this long fails an assertion
        /// (default 10 s; nil in release builds), if the main thread used
        /// CPU for at least half of it (``hangFailsAssertion(elapsedNanos:mainThreadCPUNanos:assertNanos:)``).
        public var hangAssertThreshold: Duration?

        /// `CMUX_NEXT_HANG_THRESHOLD_MS` lowers the threshold for a
        /// diagnostic launch (for example 8 to sample one-frame stalls);
        /// the default is 50 ms.
        public static var environmentThreshold: Duration {
            let raw = ProcessInfo.processInfo.environment["CMUX_NEXT_HANG_THRESHOLD_MS"].flatMap(Int.init) ?? 50
            return .milliseconds(min(max(raw, 4), 1_000))
        }

        /// The debug assertion is useful for interactive launches, but an
        /// isolated diagnostic or bench launch (``LaunchIsolation/isolated``)
        /// must stay alive long enough to preserve its watchdog evidence after
        /// reporting a hang.
        public static var defaultHangAssertThreshold: Duration? {
            hangAssertThreshold(debugBuild: ControlService.isDebugBuild,
                                isolatedLaunch: LaunchIsolation(environment: ProcessInfo.processInfo.environment).isolated)
        }

        /// Policy seam kept explicit so diagnostic-launch behavior is tested
        /// without mutating the process environment.
        public static func hangAssertThreshold(debugBuild: Bool, isolatedLaunch: Bool) -> Duration? {
            debugBuild && !isolatedLaunch ? .seconds(10) : nil
        }

        public init(threshold: Duration = Configuration.environmentThreshold, capacity: Int = 128, sampleStacks: Bool = true,
                    logStalls: Bool = ControlService.isDebugBuild, hangThreshold: Duration = .seconds(2),
                    hangReportInterval: Duration = .seconds(300),
                    hangAssertThreshold: Duration? = Configuration.defaultHangAssertThreshold) {
            self.threshold = threshold
            self.capacity = capacity
            self.sampleStacks = sampleStacks
            self.logStalls = logStalls
            self.hangThreshold = hangThreshold
            self.hangReportInterval = hangReportInterval
            self.hangAssertThreshold = hangAssertThreshold
        }
    }
}
