public import CmuxHomeCore
public import CmuxNextHome
public import CmuxNextHomeModel
import CmuxNextCompat

extension ChiefIntroStore {
    /// Shows the Chief's first-open intro on `transcript` once, when conversation `id` is a Chief chat with no
    /// messages and nothing holds it: the only Chief welcomes once per install (``ChiefIntroKind/welcome``), a Chief
    /// made beside others asks what to focus on, once per Chief.
    /// - Parameters:
    ///   - transcript: The Chief chat's transcript.
    ///   - id: The Chief chat.
    ///   - store: Home's conversations.
    ///   - archivedChiefs: The archived and deleted Chiefs' agent ids (``HomeArchivedChiefs``), read on each change.
    ///   - holds: Whether the intro waits now (Meet Chief, ``ChiefOnboarding/holdsWelcome``).
    ///   - playWelcome: Plays the welcome in the chat itself (``ChiefWelcomePlayer``); false keeps the first-run intro
    ///     (a cloud Chief, or an owner not connected yet).
    /// - Returns: The watch; it ends once the intro showed, or when the caller cancels it with its view.
    public func follow(in transcript: HomeNativeTranscriptView, conversation id: ConversationID, store: HomeStore,
                       archivedChiefs: @escaping @MainActor @Sendable () -> Set<String>,
                       holds: @escaping @MainActor @Sendable () -> Bool,
                       playWelcome: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        let intro = self
        // task-owner: lives until the intro showed or the caller cancels it with its view; event-driven (Observation
        // of the store and of what holds it).
        return Task { [weak transcript] in
            for await kind in ObservationStream({ () -> ChiefIntroKind? in
                guard !holds(), let summary = store.rows.first(where: { $0.summary.id == id })?.summary,
                      summary.lastSeq == 0, summary.participants.contains(where: { $0.agentClass == .chief }) else { return nil }
                let others = HomeArchivedChiefs(archivedChiefs(), me: store.me?.id).otherChiefs(than: id, in: store.rows)
                return intro.intro(for: id, otherChiefs: others)
            }) {
                guard let kind else { continue }
                guard let transcript else { return }
                if kind == .welcome, playWelcome() { return }
                transcript.welcomesInChat = false
                intro.markShown(kind, for: id)
                transcript.showFirstRunIntro(kind)
                return
            }
        }
    }
}
