public import CmuxHomeCore
public import CmuxNextActions
public import CmuxNextHome
public import CmuxNextHomeModel
import CmuxNextCompat

extension ChiefOnboarding {
    /// Shows Meet Chief on `transcript` while conversation `id` is the person's only Chief chat with no messages, runs
    /// the card's clicks on this model, and ends it for good when a first message arrives (the person started
    /// chatting). Every Home view follows this one model, so each window shows the same step.
    /// - Parameters:
    ///   - transcript: The Chief chat's transcript.
    ///   - id: The Chief chat.
    ///   - store: Home's conversations.
    ///   - archivedChiefs: The archived and deleted Chiefs' agent ids (``HomeArchivedChiefs``), read on each change.
    ///   - registry: Opens Settings at the setting a step names.
    /// - Returns: The watch; the caller cancels it with its view.
    public func follow(in transcript: HomeNativeTranscriptView, conversation id: ConversationID, store: HomeStore,
                       archivedChiefs: @escaping @MainActor @Sendable () -> Set<String>,
                       registry: ActionRegistry) -> Task<Void, Never> {
        transcript.onChiefOnboarding = { [weak self] action in
            guard let self else { return }
            switch action {
            case .next: next()
            case .back: back()
            case .skip: finish()
            case .choose(let mode): choose(mode)
            case .density(let density): chooseDensity(density)
            case .textSize(let points): changeTextSize(by: points)
            case .openSettings(let step):
                let setting = step == .look ? "appearance.density" : "chief.permissionMode"
                _ = registry.perform("openSettings", invocation: ActionInvocation(arguments: ["setting": .string(setting)], origin: .user))
            }
        }
        /// Where the chat is: the person's only Chief with no messages yet (`empty`), or with messages (`chatting`).
        enum Place: Equatable, Sendable { case empty, chatting, other }
        // task-owner: lives until the caller cancels it with its view; event-driven (Observation of this model, the
        // settings it reads and the store).
        return Task { [weak self, weak transcript] in
            for await (place, state) in ObservationStream({ [weak self] () -> (Place, HomeChiefOnboardingState?) in
                guard let self, shows, let summary = store.rows.first(where: { $0.summary.id == id })?.summary,
                      summary.participants.contains(where: { $0.agentClass == .chief }),
                      HomeArchivedChiefs(archivedChiefs(), me: store.me?.id).otherChiefs(than: id, in: store.rows) == 0
                else { return (.other, nil) }
                return summary.lastSeq == 0 ? (.empty, HomeChiefOnboardingState(self)) : (.chatting, nil)
            }) {
                guard let self, let transcript else { return }
                if place == .chatting { finish() }
                transcript.showChiefOnboarding(state)
            }
        }
    }

    /// Debug and capture tours (`debug.onboarding`): `meet_chief` shows Meet Chief again at `step` (meet, access,
    /// look; default meet), `meet_chief_next`, `meet_chief_back` and `meet_chief_end` act as its buttons do, and any
    /// other `meet_chief*` action only reads it.
    /// - Returns: The state after the action, as text.
    public func debugRun(_ action: String, step: String?) -> [String: String] {
        switch action {
        case "meet_chief":
            reopen()
            let target = step.flatMap(ChiefOnboardingStep.init(rawValue:)) ?? .meet
            while self.step != target, !isLast { next() }
        case "meet_chief_next": next()
        case "meet_chief_back": back()
        case "meet_chief_end": finish()
        default: break
        }
        return ["shows": "\(shows)", "decided": "\(decided)", "step": self.step.rawValue, "mode": mode.rawValue,
                "density": density?.rawValue ?? "none", "text_size": "\(textSize)", "write_failed": "\(writeFailed)"]
    }
}
