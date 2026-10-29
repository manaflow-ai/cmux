#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat

/// Names the code a long non-Swift callout of the main run loop ran, for ``InputTurnCalloutTimer``
/// (task 022): the timer arms it when a callout starts in or near an input turn; if that callout is
/// still open ``defaultThresholdNanos`` later (a ``DemandTimer`` on the injected clock, off the main
/// thread), it takes one sample of the main thread's stack (the injected `sample`: `thread_suspend`
/// and a frame-pointer walk, as the hang watchdog does), resolves it and publishes the callout's site
/// (``HopFrameResolver/calloutSite(_:)``) for the timer to record with the callout's time. The main
/// thread stores a word and reschedules the deadline to arm, and reads the published words at the
/// callout's end. Chrome names a long main-thread task by sampling it the same way:
/// `base/profiler/stack_sampling_profiler.cc` (and `base/threading/hang_watcher.cc` for hangs).
///
/// ```swift
/// let mainStack = ThreadStackSampler(thread: mach_thread_self()) // CmuxNextControl, on the main thread
/// let sampler = CalloutStackSampler { mainStack.sample() }
/// let timer = InputTurnCalloutTimer(diagnostics: hops, sampler: sampler) { turn() }
/// ```
public final class CalloutStackSampler: Sendable {
    /// How long a callout runs before it is sampled.
    public static let defaultThresholdNanos: UInt64 = 2_000_000

    /// Where a sampled stack's site is: its index, and whether the callout ran a Swift job.
    typealias SiteFinder = @Sendable ([UInt]) -> (index: Int, swiftJob: Bool)?

    private let threshold: Duration
    /// The one pending sample: arming the next callout replaces it.
    private let deadline: DemandTimer
    private let sample: @Sendable () -> [UInt]
    private let findSite: SiteFinder
    /// A sample is being taken (the sampler's buffer has one user at a time).
    private let sampling = Atomic<Bool>(false)
    /// The generation of the callout open now; 0 when none is.
    private let open = Atomic<UInt64>(0)
    /// The generation whose sample the words below hold; 0 while they are written.
    private let published = Atomic<UInt64>(0)
    private let siteAddress = Atomic<UInt>(0)
    private let swiftJob = Atomic<Bool>(false)
    private let count = Atomic<Int>(0)
    private let words: [HopWord] = (0..<HopRecord.depth).map { _ in HopWord() }

    /// - Parameters:
    ///   - thresholdNanos: How long a callout runs before it is sampled.
    ///   - clock: The deadline's clock (tests: a manual one).
    ///   - sample: The main thread's return addresses now, innermost first; called off the main
    ///     thread, one call at a time.
    public convenience init(thresholdNanos: UInt64 = CalloutStackSampler.defaultThresholdNanos,
                            clock: any Clock<Duration> = ContinuousClock(),
                            sample: @escaping @Sendable () -> [UInt]) {
        self.init(thresholdNanos: thresholdNanos, clock: clock, findSite: { CalloutStackSampler.resolveSite($0) }, sample: sample)
    }

    /// - Parameter findSite: The site of a sampled stack (tests: a fixed index).
    init(thresholdNanos: UInt64, clock: any Clock<Duration>, findSite: @escaping SiteFinder, sample: @escaping @Sendable () -> [UInt]) {
        threshold = .nanoseconds(thresholdNanos)
        // timer-class-allow: debug sampler: it samples the main thread's stack, so its deadline runs off main
        deadline = DemandTimer(owner: "input-turn-hops.sampler", clock: clock)
        self.findSite = findSite
        self.sample = sample
    }

    /// Resolves `stack` (`dladdr`: off the main thread only) and finds its callout's site.
    static func resolveSite(_ stack: [UInt]) -> (index: Int, swiftJob: Bool)? {
        var resolver = ImageOffsetResolver()
        return HopFrameResolver.calloutSite(stack.map { resolver.resolve($0) })
    }

    // MARK: The main thread

    /// The callout of `generation` (unique, never 0) started: sample it if it is still open after
    /// the threshold.
    func arm(_ generation: UInt64) {
        open.store(generation, ordering: .releasing)
        // Exact: a sample later than the threshold misses the callouts it is for (DEBUG and bench builds only).
        deadline.schedule(after: threshold, tolerance: .zero) { [self] in take(generation) }
    }

    /// The open callout ended; a sample that has not started will not.
    func disarm() {
        open.store(0, ordering: .releasing)
    }

    /// Sets `record`'s site, Swift-job flag and stack from the sample of `generation`, when one was
    /// published (call after ``disarm()``). No allocation.
    func fill(_ record: inout HopRecord, generation: UInt64) {
        guard published.load(ordering: .acquiring) == generation else { return }
        var sampled = record
        sampled.site = siteAddress.load(ordering: .acquiring)
        sampled.swiftJob = swiftJob.load(ordering: .acquiring)
        let depth = min(count.load(ordering: .acquiring), HopRecord.depth)
        withUnsafeMutableBytes(of: &sampled.addresses) { raw in
            let slots = raw.bindMemory(to: UInt.self)
            for index in 0..<depth { slots[index] = words[index].value.load(ordering: .acquiring) }
        }
        sampled.addressCount = depth
        // An older sample that passed its open check before this callout started may be writing
        // the words now: it cleared `published` first, so the words read are this one's only if
        // `published` still names it.
        guard published.load(ordering: .acquiring) == generation else { return }
        record = sampled
    }

    // MARK: Off the main thread

    /// Samples the callout of `generation` if it is still open (the deadline; tests call it).
    func take(_ generation: UInt64) {
        guard open.load(ordering: .acquiring) == generation, !sampling.exchange(true, ordering: .acquiringAndReleasing) else { return }
        defer { sampling.store(false, ordering: .releasing) }
        let stack = sample()
        // Still open after the sample: the stack is this callout's.
        guard open.load(ordering: .acquiring) == generation, let found = findSite(stack), stack.indices.contains(found.index) else { return }
        // The innermost frames up to the site, the site last.
        let kept = stack[max(0, found.index + 1 - HopRecord.depth)...found.index]
        published.store(0, ordering: .sequentiallyConsistent)
        siteAddress.store(stack[found.index], ordering: .releasing)
        swiftJob.store(found.swiftJob, ordering: .releasing)
        count.store(kept.count, ordering: .releasing)
        for (word, address) in zip(words, kept) { word.value.store(address, ordering: .releasing) }
        published.store(generation, ordering: .releasing)
    }
}
#endif
