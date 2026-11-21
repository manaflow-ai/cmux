public import CmuxHomeCore
import CmuxNextActions
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
    /// The app's Chief Homes (``HomeChiefHomes/turnActions(for:)``): Stop and the pill's Start now row run its
    /// registry's actions. Nil: neither.
    private weak var homes: HomeChiefHomes?

    public convenience init(transcript: HomeNativeTranscriptView) {
        self.init(transcript: transcript, homes: nil)
    }

    init(transcript: HomeNativeTranscriptView, homes: HomeChiefHomes?) {
        self.transcript = transcript
        self.homes = homes
        transcript.onContinue = { [weak self] in self?.continueTurn() }
        // The stop button (a click, Esc, Cmd-.) runs the shared stop action (HomeChiefActions in the App).
        if let homes {
            transcript.onStop = { [weak homes] in _ = homes?.registry?.perform("home.stopChief", invocation: ActionInvocation(origin: .user)) }
        }
    }

    /// This Home's transcript and its Chief control while it can start a queued agent (a Chief of this Mac or
    /// a paired server); nil otherwise.
    var startingChief: (transcript: HomeNativeTranscriptView, control: HomeChiefTurnControl)? {
        guard let transcript, let control else { return nil }
        return (transcript, control)
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
        // `/` lists this Chief's skills when its host runs here: it reads the same folders (slash_skills.rs).
        transcript?.slashSkillsHome = self.control?.brainHome
        // Start now on a queued agent's pill card: this chat's own Chief starts it past the cap.
        transcript?.onStartAgent = self.control.map { control in { peer in await control.startNow(peer) == nil } }
        // Its menu's Start now is the registered action's row, on this chat's Chief.
        let conversation = transcript?.conversationID.rawValue ?? ""
        transcript?.startAgentMenuItem = { [weak homes] peer in
            homes?.registry?.makeContextMenuItem(for: HomeChiefHomes.startQueuedAgent, in: .agentChat,
                                                 arguments: ["agent": .string(peer), "conversation": .string(conversation)])
        }
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
