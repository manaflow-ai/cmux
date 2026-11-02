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

    /// - Parameters:
    ///   - mainThreadCPU: CPU the main thread used since the stall began.
    ///   - pageIns: The process's page-ins since the stall's first sample.
    ///   - faults: The process's page faults since the stall's first sample.
    public init(mainThreadCPU: Duration? = nil, pageIns: UInt64? = nil, faults: UInt64? = nil) {
        self.mainThreadCPU = mainThreadCPU
        self.pageIns = pageIns
        self.faults = faults
    }
}

extension HangLoad {
    /// The hang file's two load lines for a hang `duration` long:
    ///
    /// ```
    /// main thread cpu: 0.100 s of 2.000 s (5%): blocked (waited: page-ins, WindowServer, a lock or another process)
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
        return [cpuLine, pageLine]
    }
}

/// `2.500 s`.
private func seconds(_ duration: Duration) -> String {
    String(format: "%.3f s", duration.fractionalMilliseconds / 1_000)
}
