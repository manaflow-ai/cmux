public import CmuxHomeCore
public import CmuxNextDaemon
public import CmuxNextHome

/// Presents the brain's owner controls in the existing transcript button and menu.
/// Eligibility and reopening messages belong to Rust; this only follows visible snapshots.
@MainActor
public final class HomeChiefTurnActions {
    private weak var transcript: HomeNativeTranscriptView?
    private var control: HomeChiefTurnControl?
    private var working = false
    private var sequence: Seq = 0
    private var generation = 0
    private var stopped = false
    private var inFlight = false

    public var onStopFailure: ((HomeChiefEngineError) -> Void)?

    public init(transcript: HomeNativeTranscriptView) {
        self.transcript = transcript
        transcript.onContinue = { [weak self] in self?.continueTurn() }
    }

    public func update(control: HomeChiefTurnControl, isChief: Bool, working: Bool, sequence: Seq) {
        let available = isChief && !control.isHosted
        if sequence != self.sequence || control.named != self.control?.named
            || available != (self.control != nil) || (working && !self.working) {
            generation += 1
            stopped = false
        }
        self.sequence = sequence
        self.working = working
        self.control = available ? control : nil
        transcript?.onChiefRetry = self.control == nil ? nil : { [weak self] message in self?.retry(message) }
        refresh()
    }

    private func refresh() {
        transcript?.continueAvailable = control != nil && stopped && !working && !inFlight
    }

    public func stop(onFailure: ((HomeChiefEngineError) -> Void)? = nil) {
        guard let control, !inFlight else { return }
        inFlight = true
        let generation = generation
        // task-owner: one stop request; ends with the daemon response
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { inFlight = false; refresh() }
            let answer = await control.stopResult()
            guard self.generation == generation else { return }
            switch answer {
            case .success(true): stopped = true
            case .failure(let error):
                onFailure?(error)
                self.onStopFailure?(error)
            default: break
            }
        }
    }

    public func stopAll() async -> Result<ChiefStopAll, HomeChiefEngineError> {
        guard let control, !inFlight else { return .failure(.other("Chief control is busy")) }
        inFlight = true
        defer { inFlight = false; refresh() }
        let answer = await control.stopAll()
        if case .success(let result) = answer, result.stopped { stopped = true }
        if case .failure(let error) = answer { onStopFailure?(error) }
        return answer
    }

    private func continueTurn() {
        guard let control, transcript?.continueAvailable == true, !inFlight else { return }
        inFlight = true
        refresh()
        let generation = generation
        // task-owner: one continue request; ends with the daemon response
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { inFlight = false; refresh() }
            let answer = await control.continueTurn()
            guard self.generation == generation else { return }
            switch answer {
            case .success(let result): stopped = result.continued != true && result.reason == "busy"
            case .failure: stopped = true
            }
        }
    }

    private func retry(_ message: MessageID) {
        guard let control else { return }
        // task-owner: one retry request; ends with the daemon response
        Task { @MainActor in _ = await control.retryChief(message: message.rawValue) }
    }
}
