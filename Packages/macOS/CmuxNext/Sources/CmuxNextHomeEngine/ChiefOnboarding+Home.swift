public import CmuxHomeCore
public import CmuxNextActions
public import CmuxNextHome
public import CmuxNextHomeModel
import CmuxNextCompat

extension ChiefOnboarding {
    /// Shows Meet Chief on `transcript` where ``place(chatAt:shownAt:otherChiefs:)`` says (the first run on the
    /// person's only, empty Chief chat; from the palette on any Chief chat), runs the card's clicks on this model, and
    /// ends it for good when a message arrives while it shows (the person started chatting). Every Home view follows
    /// this one model, so each window shows the same step.
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
        // task-owner: lives until the caller cancels it with its view; event-driven (Observation of this model, the
        // settings it reads and the store).
        return Task { [weak self, weak transcript] in
            var shownAt: UInt64?  // the chat's newest message when the card first showed here
            // The Chief chat as the card reads it (nil: not a Chief chat): its newest message, the other Chiefs, the
            // card's state while it shows (read here, so a step's change runs the loop) and whether it was reopened.
            for await seen in ObservationStream({ [weak self] () -> (lastSeq: UInt64, others: Int, state: HomeChiefOnboardingState?, reopened: Bool)? in
                guard let self, let summary = store.rows.first(where: { $0.summary.id == id })?.summary,
                      summary.participants.contains(where: { $0.agentClass == .chief }) else { return nil }
                let others = HomeArchivedChiefs(archivedChiefs(), me: store.me?.id).otherChiefs(than: id, in: store.rows)
                return (summary.lastSeq, others, shows ? HomeChiefOnboardingState(self) : nil, reopened)
            }) {
                guard let self, let transcript else { return }
                let spot = seen.map { self.place(chatAt: $0.lastSeq, shownAt: shownAt, otherChiefs: $0.others) } ?? .hidden
                if spot == .ends { finish() }
                shownAt = spot == .shows ? shownAt ?? seen?.lastSeq : nil
                transcript.showChiefOnboarding(spot == .shows ? seen?.state : nil)
            }
        }
    }

    /// Meet Chief in the palette (`home.meetChief`): shows the card again from its first step and brings the Chief
    /// chat forward (`home.show`, then `home.openChief`), also when the chat has messages.
    /// - Parameter registry: The app's actions.
    public func bindMeetChief(into registry: ActionRegistry) {
        registry.bindEffect("home.meetChief") { [weak self, weak registry] invocation in
            self?.reopen()
            _ = registry?.perform("home.show", invocation: invocation)
            _ = registry?.perform("home.openChief", invocation: invocation)
            return .done
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
