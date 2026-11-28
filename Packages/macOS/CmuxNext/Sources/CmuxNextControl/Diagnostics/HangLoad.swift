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
    /// The host's memory over the stall (swap, compressor, page-ins, pressure); nil when unknown.
    public var memory: HostMemoryDelta?
    /// The main thread was parked in a nested run loop taking no input (``StallVerdict/waiting``).
    public var idleWait: Bool
    /// The checked blocking call the main thread was inside when the hang was sampled
    /// (``BlockingOpenCall/summary``: `file-io at CmuxNextFiles/FileStore.swift:42`); nil when none was open.
    public var blockingCall: String?
    /// This whole process's CPU over the stall, in cores (2.5: two and a half cores busy on average);
    /// nil when unknown. Decides a starved stall's ``StallCause``.
    public var processCores: Double?

    /// - Parameters:
    ///   - mainThreadCPU: CPU the main thread used since the stall began.
    ///   - pageIns: The process's page-ins since the stall's first sample.
    ///   - faults: The process's page faults since the stall's first sample.
    ///   - host: The host's load averages and core count.
    ///   - memory: The host's memory over the stall.
    ///   - idleWait: The main thread sat in a nested run loop.
    ///   - blockingCall: The checked blocking call the main thread was inside.
    ///   - processCores: This process's CPU over the stall, in cores.
    public init(mainThreadCPU: Duration? = nil, pageIns: UInt64? = nil, faults: UInt64? = nil, host: HostLoad? = nil,
                memory: HostMemoryDelta? = nil, idleWait: Bool = false, blockingCall: String? = nil,
                processCores: Double? = nil) {
        self.mainThreadCPU = mainThreadCPU
        self.pageIns = pageIns
        self.faults = faults
        self.host = host
        self.memory = memory
        self.idleWait = idleWait
        self.blockingCall = blockingCall
        self.processCores = processCores
    }

    /// Who held up a hang `duration` long (``StallVerdict/classify(wall:mainThreadCPU:host:idleWait:)``).
    public func verdict(duration: Duration) -> StallVerdict {
        StallVerdict.classify(wall: duration, mainThreadCPU: mainThreadCPU, host: host, idleWait: idleWait)
    }

    /// The thread state under that verdict (``StallCause``); nil when unknown.
    public func cause(duration: Duration) -> StallCause? {
        StallCause.classify(verdict: verdict(duration: duration), wall: duration, mainThreadCPU: mainThreadCPU,
                            processCores: processCores, host: host)
    }
}

extension HangLoad {
    /// The hang file's load lines for a hang `duration` long:
    ///
    /// ```
    /// verdict: starved (the Mac starved the main thread of CPU (...))
    /// cause: host-load (runnable but other processes held the cores: not our code; this process 0.4 cores)
    /// main thread cpu: 0.100 s of 2.000 s (5%): blocked (waited: page-ins, WindowServer, a lock or another process)
    /// host load: 205.1 / 172.0 / 144.3 on 10 cores (overloaded)
    /// page-ins: 812, faults: 30500 (this process, since the stall's first sample)
    /// host memory: swap 2.1 GB (+180.0 MB), compressed 412000, free 3100 pages, host page-ins 9400, pressure warning (pressured)
    /// blocking call: file-io at CmuxNextFiles/FileStore.swift:42 (move it off the main thread: ...)
    /// ```
    ///
    /// The last line only when a checked blocking call was open (``BlockingOpenCall``).
    ///
    /// Busy is CPU for at least half of the hang, the line the debug busy-hang fault draws too
    /// (``MainThreadWatchdog/hangIsBusy(elapsedNanos:mainThreadCPUNanos:assertNanos:)``).
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
        let memoryLine = memory?.line(duration: duration, processPageIns: pageIns) ?? "host memory: unknown"
        let process = processCores.map { String(format: "; this process %.1f cores", $0) } ?? ""
        let causeLine = cause(duration: duration).map { "cause: \($0.rawValue) (\($0.explanation)\(process))" } ?? "cause: unknown"
        // An idle wait has no thread state to split; every other verdict says its cause, or that it is unknown.
        let lines = ["verdict: \(who.rawValue) (\(who.explanation))"] + (who == .waiting ? [] : [causeLine])
            + [cpuLine, host?.line ?? "host load: unknown", pageLine, memoryLine]
        guard let blockingCall else { return lines }
        return lines + ["blocking call: \(blockingCall) (move it off the main thread: plans/cmux-next/threading-model.md)"]
    }
}

/// `2.500 s`.
private func seconds(_ duration: Duration) -> String {
    String(format: "%.3f s", duration.fractionalMilliseconds / 1_000)
}
