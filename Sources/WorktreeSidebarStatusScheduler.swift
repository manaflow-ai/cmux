/// Serializes visible-row status probes without assuming cancellation kills subprocesses.
@MainActor
final class WorktreeSidebarStatusScheduler {
    enum ProbeResult: Sendable {
        case success(WorktreeSidebarStatus)
        case failure
    }

    typealias Probe = @MainActor @Sendable (String) async -> ProbeResult
    typealias Completion = @MainActor @Sendable (String, ProbeResult) -> Void

    private let delay: Duration
    private let probe: Probe
    private let completion: Completion
    private let clock = ContinuousClock()
    private var queue = WorktreeSidebarStatusQueue()
    private var isRunning = false
    private var lifecycleGeneration: UInt64 = 0
    private var sleepRequestID: UInt64 = 0
    private var inFlightPath: String?
    private var lastProbeCompletedAt: ContinuousClock.Instant?
    private var probeTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?

    init(
        delay: Duration,
        probe: @escaping Probe,
        completion: @escaping Completion
    ) {
        self.delay = delay
        self.probe = probe
        self.completion = completion
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lifecycleGeneration &+= 1
        drive()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lifecycleGeneration &+= 1
        queue.removeAll()
        cancelSleep()
        // CommandRunner cancellation does not terminate a launched subprocess.
        // Keep the in-flight task registered until its actual result returns.
    }

    @discardableResult
    func enqueue(path: String) -> Bool {
        guard isRunning,
              queue.enqueue(path: path, eligibleAt: clock.now.advanced(by: delay)) else {
            return false
        }
        drive()
        return true
    }

    func remove(path: String) {
        guard queue.remove(path: path) else { return }
        restartSleep()
    }

    private func drive() {
        guard isRunning,
              inFlightPath == nil,
              sleepTask == nil,
              let path = queue.firstPath else {
            return
        }
        let requestedDeadline = queue.eligibleAt(for: path) ?? clock.now
        let spacingDeadline = lastProbeCompletedAt?.advanced(by: delay) ?? requestedDeadline
        let deadline = max(requestedDeadline, spacingDeadline)
        guard deadline > clock.now else {
            beginProbe()
            return
        }

        sleepRequestID &+= 1
        let requestID = sleepRequestID
        let clock = clock
        sleepTask = Task { @MainActor [weak self] in
            // This bounded, cancellable delay is the intended probe debounce.
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self, self.sleepRequestID == requestID else { return }
            self.sleepTask = nil
            self.beginProbe()
        }
    }

    private func beginProbe() {
        guard isRunning,
              inFlightPath == nil,
              let path = queue.popFirst() else {
            return
        }
        inFlightPath = path
        let generation = lifecycleGeneration
        let probe = probe
        probeTask = Task { @MainActor [weak self] in
            let result = await probe(path)
            self?.completeProbe(path: path, result: result, generation: generation)
        }
    }

    private func completeProbe(
        path: String,
        result: ProbeResult,
        generation: UInt64
    ) {
        guard inFlightPath == path else { return }
        inFlightPath = nil
        probeTask = nil
        lastProbeCompletedAt = clock.now
        if isRunning, lifecycleGeneration == generation {
            completion(path, result)
        }
        drive()
    }

    private func restartSleep() {
        cancelSleep()
        drive()
    }

    private func cancelSleep() {
        sleepRequestID &+= 1
        sleepTask?.cancel()
        sleepTask = nil
    }
}
