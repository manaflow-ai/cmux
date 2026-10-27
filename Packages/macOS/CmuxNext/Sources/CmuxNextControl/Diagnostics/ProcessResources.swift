public import CmuxNextMetrics
public import CmuxNextWakeups

/// When the per-process memory, CPU and idle disk histograms are sampled, and which processes each sample reads
/// (task 121, plans/cmux-next/chrome-parity/p09-observability.md): when the app resigns or becomes active, and before a
/// hang report is built. No timer and no observer of its own: the app's one resign and become-active subscription
/// (`AppServices.startIdleWakeups`) and the hang reports' triggers call it.
///
/// The pids come from known sources only, never a scan of processes (``Sources``): what the main thread knows (the
/// local daemon's `identify` pid, the connected browser host's, the Chromium host's), what only an answer names (the
/// daemon's terminal hosts, acpmux and its agent hosts), and the app's own children listed on the lane (this process's
/// Chromium helpers by type, the Chromium host's helpers).
///
/// Order: every sample, transitions and reports alike, goes through one queue that one task takes in post order (a
/// `SequencedTaskRunner`, base/task/sequenced_task_runner.h), and each sample's reads are awaited, so the startup fence
/// never holds one behind a later one. A report so never overtakes a queued become-active, and an idle period is never
/// open while the app is active.
///
/// Asking: a resign and a report ask the sources that need an answer; a become-active asks nothing and reuses the
/// last answers, so the daemon gets no request at the moment the person comes back to type (an idle period counts only
/// the processes known at both of its ends anyway). A source that does not answer keeps its last answer.
///
/// The asks are awaited and the reads and the recording (``ProcessResourceSampler``) run on the `system` lane; the
/// main thread only numbers the transition, reads ``Sources/current`` and queues it.
@MainActor public final class ProcessResources {
    public typealias KnownProcess = ProcessResourceSampler.KnownProcess

    /// Where the pids come from (the tests' seam).
    public struct Sources: Sendable {
        /// What the main thread knows now: the local daemon's pid (its `identify` reply), the connected browser host's,
        /// the Chromium host's.
        public var current: @MainActor @Sendable () -> [KnownProcess]
        /// The processes only an answer names, one source each: the daemon's terminal hosts, acpmux and its agent
        /// hosts. Nil: the source did not answer, and its last answer stays.
        public var asked: [@Sendable () async -> [KnownProcess]?]
        /// This process and the app's children among and under `known` (its Chromium helpers by type, the Chromium
        /// host's). Blocking system calls: it runs on the lane.
        public var listed: @Sendable (_ known: [KnownProcess]) -> [KnownProcess]

        public init(current: @escaping @MainActor @Sendable () -> [KnownProcess], asked: [@Sendable () async -> [KnownProcess]?],
                    listed: @escaping @Sendable (_ known: [KnownProcess]) -> [KnownProcess]) {
            self.current = current
            self.asked = asked
            self.listed = listed
        }
    }

    /// One queued sample.
    private struct Request: Sendable {
        var transition: ProcessResourceSampler.Transition
        /// Whether it asks ``Sources/asked`` first.
        var asks: Bool
        var priority: WorkPriority
        var current: [KnownProcess]
        /// Called once it is recorded (or dropped), with what it recorded.
        var recorded: (@Sendable (ProcessResourceSampler.Sample?) -> Void)?
    }

    /// Reads and records the samples.
    public let sampler: ProcessResourceSampler
    private let sources: Sources
    private let requests: AsyncStream<Request>.Continuation
    /// The last transition's number: the sampler drops one older than one it applied.
    private var sequence: UInt64 = 0
    /// The most samples that wait at once; a sample past it is not taken (a report's then returns nil). Transitions
    /// come at the person's pace, so a full queue means its task is not running (quit).
    private static let queueLimit = 64

    /// - Parameters:
    ///   - sampler: Reads and records the samples.
    ///   - work: Runs the queue's task and the reads (lane `system`).
    ///   - sources: Where the pids come from.
    public init(sampler: ProcessResourceSampler = ProcessResourceSampler(), work: BackgroundWork, sources: Sources) {
        self.sampler = sampler
        self.sources = sources
        let (stream, requests) = AsyncStream<Request>.makeStream(bufferingPolicy: .bufferingOldest(Self.queueLimit))
        self.requests = requests
        // task-owner: the samples' one queue, for this object's life: deinit finishes the stream and quit cancels it.
        work.task(.bestEffort) { [sampler, sources] in
            await ProcessResources.take(stream, sampler: sampler, sources: sources, work: work)
        }
    }

    deinit {
        requests.finish()
    }

    /// The app stopped being the active app: an idle period opens.
    public func appDidResignActive() {
        enqueue(.resignActive, asks: true, priority: .bestEffort)
    }

    /// The app became the active app: the idle period records.
    public func appDidBecomeActive() {
        enqueue(.becomeActive, asks: false, priority: .bestEffort)
    }

    /// A sample before a report is built, after every sample queued before it: returns once it is recorded, so the
    /// report carries it, with what it recorded (nil when it could not run).
    @discardableResult
    public func sampleNow() async -> ProcessResourceSampler.Sample? {
        let (recorded, done) = AsyncStream<ProcessResourceSampler.Sample?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        enqueue(.report, asks: true, priority: .userVisible) { sample in
            done.yield(sample)
            done.finish()
        }
        for await sample in recorded { return sample }
        return nil
    }

    private func enqueue(_ trigger: ProcessResourceSampler.Trigger, asks: Bool, priority: WorkPriority,
                         recorded: (@Sendable (ProcessResourceSampler.Sample?) -> Void)? = nil) {
        sequence &+= 1
        let request = Request(transition: .init(trigger: trigger, sequence: sequence), asks: asks, priority: priority,
                              current: sources.current(), recorded: recorded)
        switch requests.yield(request) {
        case .enqueued: break
        case .dropped, .terminated: recorded?(nil)
        @unknown default: recorded?(nil)
        }
    }

    /// Takes the queue in order, one sample at a time, until it finishes.
    private nonisolated static func take(_ stream: AsyncStream<Request>, sampler: ProcessResourceSampler, sources: Sources,
                                         work: BackgroundWork) async {
        var answers: [[KnownProcess]] = sources.asked.map { _ in [] }
        for await request in stream {
            if request.asks {
                var fresh: [[KnownProcess]] = []
                for (ask, last) in zip(sources.asked, answers) { fresh.append(await ask() ?? last) }
                answers = fresh
            }
            let known = request.current + answers.joined()
            let listed = sources.listed, transition = request.transition
            let sample = try? await work.run(request.priority, mayBlock: .system) {
                sampler.sample(listed(known) + known, at: transition)
            }
            request.recorded?(sample)
        }
    }
}
