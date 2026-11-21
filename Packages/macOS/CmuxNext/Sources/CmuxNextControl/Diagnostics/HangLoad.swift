import Foundation

/// What the main thread and the process did during a hang, so its file tells a busy main
/// thread (its own work) from a blocked one (page-ins, WindowServer, a lock, another process).
public struct HangLoad: Sendable, Equatable {
    /// CPU the main thread used since the stall began; nil when it could not be read.
    public var mainThreadCPU: Duration?
    /// The process's page-ins (reads from disk or swap) since the watchdog first sampled the
    /// stall; nil when unknown.
    public var pageIns: UInt64?
    /// The process's page faults over the same span; nil when unknown.
    public var faults: UInt64?
    /// The host's load when last measured; nil when unknown (``StallVerdict``).
    public var host: HostLoad?
    /// The main thread was parked in a nested run loop taking no input (``StallVerdict/waiting``).
    public var idleWait: Bool

    /// - Parameters:
    ///   - mainThreadCPU: CPU the main thread used since the stall began.
    ///   - pageIns: The process's page-ins since the stall's first sample.
    ///   - faults: The process's page faults since the stall's first sample.
    ///   - host: The host's load averages and core count.
    ///   - idleWait: The main thread sat in a nested run loop.
    public init(mainThreadCPU: Duration? = nil, pageIns: UInt64? = nil, faults: UInt64? = nil, host: HostLoad? = nil,
                idleWait: Bool = false) {
        self.mainThreadCPU = mainThreadCPU
        self.pageIns = pageIns
        self.faults = faults
        self.host = host
        self.idleWait = idleWait
    }

    /// Who held up a hang `duration` long (``StallVerdict/classify(wall:mainThreadCPU:host:idleWait:)``).
    public func verdict(duration: Duration) -> StallVerdict {
        StallVerdict.classify(wall: duration, mainThreadCPU: mainThreadCPU, host: host, idleWait: idleWait)
    }
}

extension HangLoad {
    /// The hang file's load lines for a hang `duration` long:
    ///
    /// ```
    /// verdict: starved (the Mac starved the main thread of CPU (...))
    /// main thread cpu: 0.100 s of 2.000 s (5%): blocked (waited: page-ins, WindowServer, a lock or another process)
    /// host load: 205.1 / 172.0 / 144.3 on 10 cores (overloaded)
    /// page-ins: 812, faults: 30500 (this process, since the stall's first sample)
    /// ```
    ///
    /// Busy is CPU for at least half of the hang, the line the debug hang assertion draws too
    /// (``MainThreadWatchdog/hangFailsAssertion(elapsedNanos:mainThreadCPUNanos:assertNanos:)``).
    func lines(duration: Duration) -> [String] {
        var cpuLine = "main thread cpu: unknown"
        if let mainThreadCPU, duration > .zero {
            let share = String(format: "%.0f", min(100, mainThreadCPU / duration * 100))
            let verdict = mainThreadCPU * 2 >= duration
                ? "busy (its own work)"
                : "blocked (waited: page-ins, WindowServer, a lock or another process)"
            cpuLine = "main thread cpu: \(seconds(mainThreadCPU)) of \(seconds(duration)) (\(share)%): \(verdict)"
        }
        let pageLine = pageIns.map { "page-ins: \($0), faults: \(faults.map(String.init) ?? "?") (this process, since the stall's first sample)" }
            ?? "page-ins: unknown"
        let who = verdict(duration: duration)
        return ["verdict: \(who.rawValue) (\(who.explanation))", cpuLine, host?.line ?? "host load: unknown", pageLine]
    }
}

/// `2.500 s`.
private func seconds(_ duration: Duration) -> String {
    String(format: "%.3f s", duration.fractionalMilliseconds / 1_000)
}
