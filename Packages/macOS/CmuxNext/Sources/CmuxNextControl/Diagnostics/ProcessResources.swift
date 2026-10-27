public import CmuxNextDaemon
public import CmuxNextMetrics
public import CmuxNextWakeups

/// When the per-process memory, CPU and idle disk histograms are sampled, and which processes each sample reads
/// (task 121, plans/cmux-next/chrome-parity/p09-observability.md): when the app resigns or becomes active, and before a
/// hang report is built. No timer and no observer of its own: the app's one resign and become-active subscription
/// (`AppServices.startIdleWakeups`) and the hang reports' triggers call it.
///
/// The pids come from known sources only, never a scan of process names:
/// - this process and its Chromium helpers by type (`localProcesses`, the app's own child list, off the main thread);
/// - the local daemon (`daemonPID`, its `identify` reply);
/// - the daemon's children, terminal hosts and acpmux, from the daemon's own status (`trace-status`,
///   ``TraceStatusRequest``). One trace control call runs at a time in the daemon, so that list is asked for only at a
///   report, and the transitions between two reports reuse the last one (a pid that ended reads as unreadable).
///
/// The reads and the recording (``ProcessResourceSampler``) run on a background lane; the main thread only numbers
/// the transition and hands over the pid list.
@MainActor public final class ProcessResources {
    public typealias KnownProcess = ProcessResourceSampler.KnownProcess

    /// Reads and records the samples.
    public let sampler: ProcessResourceSampler
    private let work: BackgroundWork
    private let localProcesses: @Sendable () -> [KnownProcess]
    private let daemonPID: @MainActor () -> Int32?
    private let daemonStatus: @MainActor () async -> TraceStatusRequest.Response?
    /// The daemon's children from its last status answer.
    private var daemonChildren: [KnownProcess] = []
    /// The last transition's number: the sampler drops one that runs after a later one.
    private var sequence: UInt64 = 0

    /// - Parameters:
    ///   - sampler: Reads and records the samples.
    ///   - work: Runs the reads (lane `system`).
    ///   - localProcesses: This process and its Chromium helpers, off the main thread.
    ///   - daemonPID: The local daemon's pid now; nil without one.
    ///   - daemonStatus: The local daemon's `trace-status`; nil without a local daemon or when it did not answer.
    public init(sampler: ProcessResourceSampler = ProcessResourceSampler(), work: BackgroundWork,
                localProcesses: @escaping @Sendable () -> [KnownProcess], daemonPID: @escaping @MainActor () -> Int32?,
                daemonStatus: @escaping @MainActor () async -> TraceStatusRequest.Response?) {
        self.sampler = sampler
        self.work = work
        self.localProcesses = localProcesses
        self.daemonPID = daemonPID
        self.daemonStatus = daemonStatus
    }

    /// The app stopped being the active app: an idle period opens.
    public func appDidResignActive() {
        post(.resignActive)
    }

    /// The app became the active app: the idle period records.
    public func appDidBecomeActive() {
        post(.becomeActive)
    }

    /// A sample before a report is built, with the daemon's children asked for again: returns once it is recorded,
    /// so the report carries it.
    public func sampleNow() async {
        if let status = await daemonStatus() { daemonChildren = Self.children(of: status) }
        let transition = next(.report), known = knownNow(), local = localProcesses, sampler = sampler
        _ = try? await work.run(.userVisible, mayBlock: .system) {
            sampler.sample(local() + known, at: transition)
        }
    }

    /// One transition's sample on the background lane, at best effort.
    private func post(_ trigger: ProcessResourceSampler.Trigger) {
        let transition = next(trigger), known = knownNow(), local = localProcesses, sampler = sampler
        work.post(.bestEffort, mayBlock: .system) {
            _ = sampler.sample(local() + known, at: transition)
        }
    }

    private func next(_ trigger: ProcessResourceSampler.Trigger) -> ProcessResourceSampler.Transition {
        sequence &+= 1
        return ProcessResourceSampler.Transition(trigger: trigger, sequence: sequence)
    }

    /// The daemon and its children as known now.
    private func knownNow() -> [KnownProcess] {
        guard let pid = daemonPID(), pid > 0 else { return daemonChildren }
        return [KnownProcess(kind: .daemon, pid: pid)] + daemonChildren
    }

    /// The terminal hosts, the holder and acpmux of a `trace-status` answer, each with a pid (the daemon's own entry
    /// is left out: its pid comes from `identify`).
    public nonisolated static func children(of status: TraceStatusRequest.Response) -> [KnownProcess] {
        status.processes.compactMap { process in
            guard let pid = process.pid, pid > 0 else { return nil }
            switch process.role {
            case "terminal-host": return KnownProcess(kind: .host, pid: pid)
            case "holder": return KnownProcess(kind: .holder, pid: pid)
            case "acpmux": return KnownProcess(kind: .acpmux, pid: pid)
            default: return nil
            }
        }
    }
}
